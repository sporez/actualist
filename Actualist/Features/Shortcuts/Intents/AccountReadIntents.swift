import AppIntents
import Foundation

struct GetAccountsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Accounts"
    static var description = IntentDescription("Returns accounts in the selected budget.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Include Closed", default: false)
    var includeClosed: Bool

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Get Accounts") {
            \.$includeClosed
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[AccountEntity]> & ProvidesDialog {
        let accounts = try await session.accounts(includeClosed: includeClosed)
        let dialog: IntentDialog
        switch accounts.count {
        case 0:
            dialog = "No accounts in the selected budget."
        case 1:
            dialog = "1 account."
        default:
            dialog = IntentDialog("\(accounts.count) accounts.")
        }
        return .result(value: accounts, dialog: dialog)
    }
}
