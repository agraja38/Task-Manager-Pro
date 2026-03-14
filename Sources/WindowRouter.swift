import SwiftUI

@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    var openMainWindow: (() -> Void)?
}
