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
        replacing previous: Task<Void, Never>?
    ) -> Task<Void, Never> {
        previous?.cancel()
        withAnimation(.snappy(duration: 0.2)) {
            appState.developerUnlockToastMessage = message
        }

        return Task { @MainActor in
            try? await Task.sleep(for: .seconds(toastDurationSeconds))
            withAnimation(.snappy(duration: 0.2)) {
                if appState.developerUnlockToastMessage == message {
                    appState.developerUnlockToastMessage = nil
                }
            }
        }
    }
}
