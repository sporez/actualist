import Foundation
import Testing
@testable import Actualist

/// The Settings budget picker closes only for an opened budget. Its selection
/// is not evidence: a failed open of the already-selected budget leaves the
/// selection unchanged. The open itself is an injected fake.
@MainActor
struct SettingsBudgetPickerSelectionTests {
    private func makeAppState() -> AppState {
        let defaults = UserDefaults(
            suiteName: "ActualistTests.SettingsBudgetPicker.\(UUID().uuidString)"
        )!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString,
                backend: FakeKeychainBackend()
            )
        )
    }

    private let budget = ActualBudget(
        budgetID: "file-a",
        cloudFileId: "file-a",
        groupId: "group-a",
        name: "Budget A",
        state: nil
    )

    @Test func selectClosesOnlyWhenTheBudgetOpens() async {
        let appState = makeAppState()
        var outcomes: [BudgetOpenOutcome] = [.opened, .failed(message: "Open failed"), .busy, .superseded]
        let model = SettingsViewModel(selectBudget: { _, _, _ in outcomes.removeFirst() })

        #expect(await model.selectBudget(budget, using: appState))
        #expect(!(await model.selectBudget(budget, using: appState)))
        #expect(!(await model.selectBudget(budget, using: appState)))
        #expect(!(await model.selectBudget(budget, using: appState)))
        #expect(model.encryptedBudgetPrompt == nil)
    }

    @Test func selectAsksForAPasswordWhenTheBudgetNeedsOne() async {
        let appState = makeAppState()
        let model = SettingsViewModel(selectBudget: { _, _, _ in .needsEncryptionPassword })
        model.encryptionPassword = "left over"

        #expect(!(await model.selectBudget(budget, using: appState)))
        #expect(model.encryptedBudgetPrompt == budget)
        #expect(model.encryptionPassword.isEmpty)
    }

    @Test func wrongPasswordForTheSelectedBudgetKeepsThePromptOpen() async {
        let appState = makeAppState()
        appState.settings.selectedBudgetID = budget.syncID
        var passwords: [String?] = []
        let model = SettingsViewModel(selectBudget: { appState, _, password in
            passwords.append(password)
            appState.lastErrorMessage = "Wrong password"
            return .failed(message: "Wrong password")
        })
        model.encryptedBudgetPrompt = budget
        model.encryptionPassword = "wrong"

        #expect(!(await model.unlockEncryptedBudget(budget, using: appState)))
        #expect(passwords == ["wrong"])
        #expect(model.encryptedBudgetPrompt == budget)
        #expect(model.encryptionPassword == "wrong")
        #expect(!model.isUnlockingEncryptedBudget)
        #expect(appState.lastErrorMessage == "Wrong password")
    }

    @Test func unlockClearsThePromptWhenTheBudgetOpens() async {
        let appState = makeAppState()
        let model = SettingsViewModel(selectBudget: { _, _, _ in .opened })
        model.encryptedBudgetPrompt = budget
        model.encryptionPassword = "right"

        #expect(await model.unlockEncryptedBudget(budget, using: appState))
        #expect(model.encryptedBudgetPrompt == nil)
        #expect(model.encryptionPassword.isEmpty)
        #expect(!model.isUnlockingEncryptedBudget)
    }
}
