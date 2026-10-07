import Foundation
import SwiftUI

/// Schedules the transient developer-unlock toast message on `AppState`.
///
/// The toast is shown in two places (the Settings root and the app icon
/// picker sheet). This helper owns the set + auto-dismiss timing so both
/// surfaces stay in sync without duplicating the animation/sleep logic.
@MainActor
enum DeveloperUnlockToast {
    static let toastDurationSeconds: Double = 1.4

    @discardableResult
    static func present(
        _ message: String,
        on appState: AppState,
        replacing previous: Task<Void, Never>?,
        duration: Duration = .seconds(toastDurationSeconds)
    ) -> Task<Void, Never> {
        previous?.cancel()
        withAnimation(.snappy(duration: 0.2)) {
            appState.developerUnlockToastMessage = message
        }

        return Task { @MainActor in
            // A replaced toast cancels this task; it must not clear the
            // message that its replacement is now showing.
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            withAnimation(.snappy(duration: 0.2)) {
                if appState.developerUnlockToastMessage == message {
                    appState.developerUnlockToastMessage = nil
                }
            }
        }
    }
}
