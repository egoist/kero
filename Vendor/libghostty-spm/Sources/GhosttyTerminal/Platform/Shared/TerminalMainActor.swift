import Foundation

@inline(__always)
func terminalRunOnMain(
    _ operation: @escaping @MainActor () -> Void
) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            operation()
        }
        return
    }

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            operation()
        }
    }
}

/// Runs an operation on the main actor and returns its result before the
/// caller continues. Runtime callbacks that return a handled/unhandled value
/// must use this instead of queueing work asynchronously.
@inline(__always)
func terminalRunOnMainSync<Result: Sendable>(
    _ operation: @escaping @MainActor () -> Result
) -> Result {
    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            operation()
        }
    }

    return DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            operation()
        }
    }
}
