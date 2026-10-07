import UIKit

/// Asks the system for extra execution time while an outbox flush attempt is
/// in flight, so a write made just before the app is suspended can finish
/// uploading. Injected so tests can observe begin/end and force expiration.
@MainActor
protocol BackgroundExecutionAssertion {
    /// `onExpiration` runs when the system is about to suspend the app. The
    /// caller still calls `end()` once its work stops.
    func begin(
        name: String,
        onExpiration: @escaping @MainActor () -> Void
    ) -> any BackgroundExecutionHandle
}

@MainActor
protocol BackgroundExecutionHandle: AnyObject {
    /// Safe to call more than once; only the first call ends the assertion.
    func end()
}

@MainActor
struct UIKitBackgroundExecutionAssertion: BackgroundExecutionAssertion {
    func begin(
        name: String,
        onExpiration: @escaping @MainActor () -> Void
    ) -> any BackgroundExecutionHandle {
        let handle = UIKitBackgroundTaskHandle()
        handle.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // The system requires the task to end inside the expiration handler.
            onExpiration()
            handle.end()
        }
        return handle
    }
}

@MainActor
private final class UIKitBackgroundTaskHandle: BackgroundExecutionHandle {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        let ended = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ended)
    }
}
