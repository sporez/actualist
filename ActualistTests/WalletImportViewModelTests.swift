import Foundation
import Testing
@testable import Actualist

@Suite("Wallet import view model")
@MainActor
struct WalletImportViewModelTests {
    @Test func accountSwitchDuringTheReadDoesNotLeaveTheOldAccountsImportedIDs() async {
        let repository = UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: [],
                categoryGroups: []
            )
        )
        let entered = TestLatch()
        let release = TestLatch()
        repository.existingImportedIDsHook = { accountID in
            guard accountID == "a" else { return [] }
            entered.trip()
            await release.wait()
            return ["imported-in-a"]
        }
        let model = WalletImportViewModel()
        model.selectedAccountID = "a"

        let older = Task { await model.refreshExistingIDs(budgetID: "budget", repository: repository) }
        defer { older.cancel(); entered.trip(); release.trip() }
        let started = await entered.wait(timeout: .seconds(5), onTimeout: { release.trip() })
        #expect(started)
        model.selectedAccountID = "b"
        await model.refreshExistingIDs(budgetID: "budget", repository: repository)
        #expect(model.existingImportedIDs.isEmpty)

        release.trip()
        await older.value

        #expect(model.existingImportedIDs.isEmpty)
    }
}
