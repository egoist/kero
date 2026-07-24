import UIKit

@MainActor
enum ApplicationExitController {
    private static var hasRequestedExit = false

    static func requestExit() {
        guard !hasRequestedExit else {
            return
        }

        hasRequestedExit = true
        suspendIfAvailable()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(EXIT_SUCCESS)
        }
    }

    private static func suspendIfAvailable() {
        let selector = NSSelectorFromString("suspend")
        let application = UIApplication.shared

        guard application.responds(to: selector) else {
            return
        }

        _ = application.perform(selector)
    }
}
