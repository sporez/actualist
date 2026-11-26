import Foundation
import Testing
@testable import Actualist

/// The Bank Sync screen with Enable Banking accounts: which accounts Sync All
/// downloads, mixed SimpleFIN and Enable Banking runs, and the copy.
@MainActor
struct EnableBankingBankSyncViewModelTests {
    private let support = LocalFirstActualStoreTests()
    private typealias StubSimpleFINTransport = LocalFirstActualStoreTests.StubSimpleFINTransport
    private typealias StubEnableBankingTransport = EnableBankingTestSupport.StubTransport

    private func makeModel(
        simpleFIN: StubSimpleFINTransport,
        enableBanking: StubEnableBankingTransport,
        linkSavingsToSimpleFIN: Bool,
        enableBankingStatus: String? = nil
    ) async throws -> (BankSyncViewModel, LocalFirstActualStoreTests.OpenedWritableStoreBundle) {
        let bundle = try await EnableBankingTestSupport.makeStore(
            support: support, simpleFIN: simpleFIN, enableBanking: enableBanking
        )
        if linkSavingsToSimpleFIN {
            try await bundle.store.bankSync.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")
        }
        try await EnableBankingTestSupport.link(
            bundle.store, accountID: "credit", remoteAccountID: "eb-acct-checking",
            bankName: "Synthetic Bank", status: enableBankingStatus
        )
        let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)
        await model.load()
        return (model, bundle)
    }

    private func simpleFINDownload(errorCode: String? = nil) -> StubSimpleFINTransport {
        StubSimpleFINTransport(
            remoteAccounts: [support.remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: errorCode == nil ? ["sfin-1": SimpleFINAccountDownload(
                    transactions: [support.remoteTransaction(id: "sf-1", amount: "-10.00", dayID: "20261001", payeeName: "Coffee Shop")],
                    startingBalance: nil, errorType: nil, errorCode: nil
                )] : [:],
                errorType: errorCode,
                errorCode: errorCode
            )
        )
    }

    private func enableBankingTransport(_ scenario: String = "booked-and-pending") throws -> StubEnableBankingTransport {
        StubEnableBankingTransport(["eb-acct-checking": .success(try EnableBankingTestSupport.download(scenario))])
    }

    // MARK: - Mixed runs

    /// A failed SimpleFIN batch names its cause once, and the Enable Banking accounts' lines stay.
    @Test func mixedWholeRequestFailureKeepsTheEnableBankingResultLines() async throws {
        let (model, _) = try await makeModel(
            simpleFIN: simpleFINDownload(errorCode: "SERVER_DOWN"),
            enableBanking: try enableBankingTransport(),
            linkSavingsToSimpleFIN: true
        )
        #expect(model.canSyncAll)

        await model.syncAll()

        #expect(model.phase == .ready)
        #expect(model.resultLines.map(\.id) == ["credit"])
        #expect(model.resultLines.first?.addedCount == 4) // three rows and the opening balance
        let run = try #require(model.lastRun)
        #expect(run.failure == .serverDown)
        #expect(run.summary.hasPrefix("Synced 1 of 2 accounts."))
        #expect(run.summary.hasSuffix(BankSyncWholeRequestFailure.serverDown.otherAccountsNote))
        #expect(model.accountLines.first { $0.id == "savings" }?.statusText == "Not synced")
    }

    @Test func simpleFINOnlyWholeRequestFailureStillShowsOneCause() async throws {
        let (model, _) = try await makeModel(
            simpleFIN: simpleFINDownload(errorCode: "SERVER_DOWN"),
            enableBanking: StubEnableBankingTransport(support: .success(.notConfigured)),
            linkSavingsToSimpleFIN: true
        )
        await model.syncAll()
        #expect(model.resultLines.isEmpty)
        #expect(model.lastRun?.summary == BankSyncWholeRequestFailure.serverDown.summary)
    }

    @Test func thrownSimpleFINFailureStillSyncsTheEnableBankingAccounts() async throws {
        // The SimpleFIN status answers; its transactions route is missing.
        let simpleFIN = StubSimpleFINTransport(remoteAccounts: [support.remoteAccount(balance: "0.00")], response: nil)
        let (model, bundle) = try await makeModel(
            simpleFIN: simpleFIN, enableBanking: try enableBankingTransport(), linkSavingsToSimpleFIN: true
        )

        await model.syncAll()

        #expect(model.resultLines.map(\.id) == ["credit"])
        guard case .failed(let message) = model.phase else {
            Issue.record("expected the SimpleFIN failure on screen")
            return
        }
        #expect(message.hasPrefix(BankSyncRunTally.simpleFINNotSyncedNote))
        #expect(model.lastRun?.summary.hasSuffix(BankSyncRunTally.simpleFINNotSyncedNote) == true)
        #expect(try await EnableBankingTestSupport.storedStatus(bundle.store, accountID: "credit") == "ok")
    }

    // MARK: - Enable Banking only

    @Test func enableBankingOnlyBudgetSyncsWithoutSimpleFIN() async throws {
        let (model, _) = try await makeModel(
            simpleFIN: StubSimpleFINTransport(support: .notConfigured),
            enableBanking: try enableBankingTransport(),
            linkSavingsToSimpleFIN: false
        )
        #expect(model.enableBankingSupport == .configured)
        #expect(model.canSyncAll)
        #expect(!model.canLinkAccounts)
        #expect(model.canEnableBackgroundSync)
        #expect(!model.showsSimpleFINTokenSection)
        let credit = try #require(model.accountLines.first { $0.id == "credit" })
        #expect(credit.provider == .enableBanking)
        #expect(credit.isSyncable)
        #expect(!credit.canUnlink)
        #expect(model.linkedAccountDisplayName(for: credit) == "Credit Card")

        await model.syncAll()
        #expect(model.phase == .ready)
        #expect(model.resultLines.map(\.id) == ["credit"])
    }

    @Test func serverWithoutEnableBankingLeavesThoseAccountsUnsynced() async throws {
        let enableBanking = StubEnableBankingTransport(support: .success(.notConfigured))
        let (model, _) = try await makeModel(
            simpleFIN: StubSimpleFINTransport(support: .notConfigured),
            enableBanking: enableBanking,
            linkSavingsToSimpleFIN: false
        )
        #expect(model.enableBankingSupport == .notConfigured)
        #expect(!model.canSyncAll)
        #expect(!model.canEnableBackgroundSync)
        #expect(model.showsSimpleFINTokenSection)
        #expect(await enableBanking.requests.isEmpty)
    }

    @Test func budgetWithoutEnableBankingAccountsNeverAsksItsStatus() async throws {
        let enableBanking = StubEnableBankingTransport()
        let bundle = try await EnableBankingTestSupport.makeStore(
            support: support, simpleFIN: simpleFINDownload(), enableBanking: enableBanking
        )
        try await bundle.store.bankSync.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")
        let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)
        await model.load()
        #expect(model.enableBankingSupport == nil)
        #expect(await enableBanking.statusRequests == 0)
        #expect(model.canSyncAll)
    }

    @Test func expiredConsentSaysToReconnectInTheWebApp() async throws {
        let (model, _) = try await makeModel(
            simpleFIN: StubSimpleFINTransport(support: .notConfigured),
            enableBanking: try enableBankingTransport(),
            linkSavingsToSimpleFIN: false,
            enableBankingStatus: "reauth-required"
        )
        let credit = try #require(model.accountLines.first { $0.id == "credit" })
        #expect(credit.statusText == "Reconnect in Actual web app")
        #expect(credit.linkedFooterText.contains("Reconnect this account in the Actual web app"))
    }

    // MARK: - Copy

    @Test func copyNamesEveryProviderTheServerServes() {
        #expect(BankSyncCopy.providerText(support: .configured, hasDeviceKey: false, enableBanking: .configured, isDemoMode: false)
            == "SimpleFIN and Enable Banking")
        #expect(BankSyncCopy.providerText(support: .notConfigured, hasDeviceKey: false, enableBanking: .configured, isDemoMode: false)
            == "Enable Banking via your server")
        #expect(BankSyncCopy.providerText(support: .notConfigured, hasDeviceKey: true, enableBanking: .configured, isDemoMode: false)
            == "SimpleFIN on this device · Enable Banking via your server")
        #expect(BankSyncCopy.providerText(support: .configured, hasDeviceKey: false, isDemoMode: false)
            == "SimpleFIN via your server")
        #expect(BankSyncCopy.providerText(support: nil, hasDeviceKey: false, enableBanking: .notConfigured, isDemoMode: false)
            == "Not connected")
        #expect(BankSyncCopy.backgroundSyncFooter(support: .notConfigured, enableBanking: .configured, phase: .ready, isDemoMode: false)
            .hasPrefix("After a background sync"))
        #expect(BankSyncCopy.backgroundSyncFooter(support: .notConfigured, phase: .ready, isDemoMode: false)
            == "Works only when SimpleFIN or Enable Banking is set up on your Actual server.")
        #expect(BankSyncCopy.statusText(durableStatus: "reauth-required", provider: .simpleFIN) == "Reconnect required")
        #expect(BankSyncCopy.statusText(durableStatus: "reauth-required", provider: .enableBanking) == "Reconnect in Actual web app")
        #expect(BankSyncCopy.statusText(durableStatus: "not-configured") == "Not set up on server")
    }
}
