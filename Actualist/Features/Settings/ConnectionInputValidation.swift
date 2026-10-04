import Foundation

/// Input checks shared by onboarding and Connection & Sync. Whitespace-only
/// values count as empty.
enum ConnectionInputValidation {
    static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func canConnect(serverURL: String, password: String, isBusy: Bool) -> Bool {
        hasContent(serverURL) && hasContent(password) && !isBusy
    }
}
