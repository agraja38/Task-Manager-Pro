import Foundation
import Security

@_silgen_name("PulseAuthorizationExecuteWithPrivileges")
private func PulseAuthorizationExecuteWithPrivileges(
    _ authorization: AuthorizationRef,
    _ pathToTool: UnsafePointer<CChar>,
    _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> OSStatus

final class FanControlService {
    private let defaultFlags = AuthorizationFlags(rawValue: 0)
    private let interactionAllowedFlags = AuthorizationFlags(rawValue: (1 << 0) | (1 << 1) | (1 << 4))
    private let destroyRightsFlags = AuthorizationFlags(rawValue: 1 << 3)
    private var cachedAuthorizationRef: AuthorizationRef?

    deinit {
        if let cachedAuthorizationRef {
            AuthorizationFree(cachedAuthorizationRef, destroyRightsFlags)
        }
    }

    func applyFanTargets(_ speedsByFanIndex: [Int: Int]) -> (success: Bool, message: String) {
        do {
            let authorizationRef = try authorizeExecution()
            let resultURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("taskmanagerpro-fancontrol-\(UUID().uuidString)")
                .appendingPathExtension("json")
            defer { try? FileManager.default.removeItem(at: resultURL) }

            let status = try launchHelper(with: speedsByFanIndex, authorizationRef: authorizationRef, resultURL: resultURL)
            guard status == errAuthorizationSuccess else {
                if status == errAuthorizationCanceled {
                    return (false, "Fan control was canceled.")
                }
                return (false, "macOS could not authorize fan control. (Status \(status))")
            }

            return try waitForResult(at: resultURL)
        } catch let error as FanControlError {
            return (false, error.localizedDescription)
        } catch {
            return (false, "Fan control failed: \(error.localizedDescription)")
        }
    }

    private func authorizeExecution() throws -> AuthorizationRef {
        let authorizationRef: AuthorizationRef
        if let existing = cachedAuthorizationRef {
            authorizationRef = existing
        } else {
            var createdAuthorization: AuthorizationRef?
            let createStatus = AuthorizationCreate(nil, nil, defaultFlags, &createdAuthorization)
            guard createStatus == errAuthorizationSuccess, let createdAuthorization else {
                throw FanControlError.authorizationFailed(createStatus)
            }
            cachedAuthorizationRef = createdAuthorization
            authorizationRef = createdAuthorization
        }

        let status = kAuthorizationRightExecute.withCString { rightName in
            var executeRight = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &executeRight) { executeRightPointer in
                var rights = AuthorizationRights(count: 1, items: executeRightPointer)
                return AuthorizationCopyRights(authorizationRef, &rights, nil, interactionAllowedFlags, nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            throw FanControlError.authorizationFailed(status)
        }

        return authorizationRef
    }

    private func launchHelper(with speedsByFanIndex: [Int: Int], authorizationRef: AuthorizationRef, resultURL: URL) throws -> OSStatus {
        guard let helperURL = Bundle.main.url(forResource: "TaskManagerProFanHelper", withExtension: nil) else {
            throw FanControlError.helperMissing
        }

        guard let toolCString = strdup(helperURL.path) else {
            throw FanControlError.executionFailed("Task Manager Pro could not prepare the helper path.")
        }
        defer { free(toolCString) }

        let arguments = [resultURL.path] + speedsByFanIndex.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }
        let cStrings = try arguments.map { argument -> UnsafeMutablePointer<CChar> in
            guard let duplicate = strdup(argument) else {
                throw FanControlError.executionFailed("Task Manager Pro could not prepare the helper arguments.")
            }
            return duplicate
        }
        defer { cStrings.forEach { free($0) } }

        var mutableArguments = cStrings.map(Optional.some)
        mutableArguments.append(nil)
        return mutableArguments.withUnsafeMutableBufferPointer { buffer in
            PulseAuthorizationExecuteWithPrivileges(authorizationRef, toolCString, buffer.baseAddress)
        }
    }

    private func waitForResult(at url: URL) throws -> (success: Bool, message: String) {
        let timeout = Date().addingTimeInterval(4.0)
        while Date() < timeout {
            if let data = try? Data(contentsOf: url),
               let result = try? JSONDecoder().decode(FanControlHelperResult.self, from: data) {
                return (result.success, result.message)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw FanControlError.executionFailed("Task Manager Pro did not get a response from the fan control helper.")
    }
}

private struct FanControlHelperResult: Decodable {
    let success: Bool
    let message: String
}

private enum FanControlError: LocalizedError {
    case authorizationFailed(OSStatus)
    case helperMissing
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(status):
            if status == errAuthorizationCanceled {
                return "Fan control was canceled."
            }
            return "Fan control authorization failed. (Status \(status))"
        case .helperMissing:
            return "Task Manager Pro could not find its bundled fan control helper."
        case let .executionFailed(message):
            return message
        }
    }
}
