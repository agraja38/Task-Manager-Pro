import Foundation
import Security

@_silgen_name("PulseAuthorizationExecuteWithPrivileges")
private func PulseAuthorizationExecuteWithPrivileges(
    _ authorization: AuthorizationRef,
    _ pathToTool: UnsafePointer<CChar>,
    _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> OSStatus

final class MemoryCleanupService {
    private let defaultFlags = AuthorizationFlags(rawValue: 0)
    private let interactionAllowedFlags = AuthorizationFlags(rawValue: (1 << 0) | (1 << 1) | (1 << 4))
    private let destroyRightsFlags = AuthorizationFlags(rawValue: 1 << 3)
    private var cachedAuthorizationRef: AuthorizationRef?

    deinit {
        if let cachedAuthorizationRef {
            AuthorizationFree(cachedAuthorizationRef, destroyRightsFlags)
        }
    }

    func clearReclaimableMemory() -> (success: Bool, message: String) {
        do {
            let authorizationRef = try authorizeExecution()
            let status = try executePurge(using: authorizationRef)

            guard status == errAuthorizationSuccess else {
                if status == errAuthorizationCanceled {
                    return (false, "Memory cleanup was canceled.")
                }
                return (false, "macOS could not clear reclaimable memory. (Authorization status \(status))")
            }

            return (true, "macOS cleared reclaimable memory where possible.")
        } catch let error as MemoryCleanupError {
            return (false, error.localizedDescription)
        } catch {
            return (false, "Memory cleanup failed: \(error.localizedDescription)")
        }
    }

    private func authorizeExecution() throws -> AuthorizationRef {
        let authorizationRef: AuthorizationRef
        if let existing = cachedAuthorizationRef {
            authorizationRef = existing
        } else {
            var createdAuthorization: AuthorizationRef?
            let createStatus = AuthorizationCreate(
                nil,
                nil,
                defaultFlags,
                &createdAuthorization
            )
            guard createStatus == errAuthorizationSuccess, let createdAuthorization else {
                throw MemoryCleanupError.authorizationFailed(createStatus)
            }
            self.cachedAuthorizationRef = createdAuthorization
            authorizationRef = createdAuthorization
        }

        let status = kAuthorizationRightExecute.withCString { rightName in
            var executeRight = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )

            return withUnsafeMutablePointer(to: &executeRight) { executeRightPointer in
                var rights = AuthorizationRights(count: 1, items: executeRightPointer)
                return AuthorizationCopyRights(authorizationRef, &rights, nil, interactionAllowedFlags, nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            throw MemoryCleanupError.authorizationFailed(status)
        }

        return authorizationRef
    }

    private func executePurge(using authorizationRef: AuthorizationRef) throws -> OSStatus {
        let toolCString = strdup("/usr/sbin/purge")
        defer { free(toolCString) }
        guard let toolCString else {
            throw MemoryCleanupError.executionFailed("macOS could not prepare the privileged tool path.")
        }

        let emptyArgument = strdup("")
        defer { free(emptyArgument) }

        guard let emptyArgument else {
            throw MemoryCleanupError.executionFailed("macOS could not prepare the privileged command arguments.")
        }

        var arguments: [UnsafeMutablePointer<CChar>?] = [emptyArgument, nil]
        return arguments.withUnsafeMutableBufferPointer { buffer in
            PulseAuthorizationExecuteWithPrivileges(
                authorizationRef,
                toolCString,
                buffer.baseAddress
            )
        }
    }
}

private enum MemoryCleanupError: LocalizedError {
    case authorizationFailed(OSStatus)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(status):
            if status == errAuthorizationCanceled {
                return "Memory cleanup was canceled."
            }
            return "Memory cleanup authorization failed. (Status \(status))"
        case let .executionFailed(message):
            return message
        }
    }
}
