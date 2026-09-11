#if DEBUG
import Observation

@MainActor
@Observable
final class DebugNotificationViewModel {
    var isPosting = false
    var message: String?

    func post(using appState: AppState) async {
        isPosting = true
        message = nil
        defer { isPosting = false }
        do {
            try await appState.postDebugNewTransactionNotification()
            message = "Test alert will post in 5 seconds. Send Actualist to the background, then tap the notification."
        } catch {
            message = error.userFacingMessage
        }
    }
}
#endif
