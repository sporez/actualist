import Foundation
import Testing
@testable import Actualist

/// The background bank-sync step with Enable Banking accounts: the account
/// filter, the `/enablebanking/status` probe, the time budget, and a SimpleFIN
/// failure beside Enable Banking accounts.
@MainActor
struct EnableBankingBackgroundApplyTests {
    private let support = LocalFirstActualStoreTests()
    private typealias StubSimpleFINTransport = LocalFirstActualStoreTests.StubSimpleFINTransport
    private typealias StubEnableBankingTransport = EnableBankingTestSupport.StubTransport

    private func simpleFIN(response: SimpleFINTransactionsResponse? = nil, support status: SimpleFINServerSupport = .configured) -> StubSimpleFINTransport {
        StubSimpleFINTransport(
            support: status,
            remoteAccounts: [support.remoteAccount(balance: "0.00")],
            response: response
        )
    }

    private func simpleFINDownload() -> SimpleFINTransactionsResponse {
        SimpleFINTransactionsResponse(
            downloads: ["sfin-1": SimpleFINAccountDownload(
                transactions: [support.remoteTransaction(id: "sf-1", amount: "-10.00", dayID: "20261001", payeeName: "Coffee Shop")],
                startingBalance: nil, errorType: nil, errorCode: nil
            )],
            errorType: nil, errorCode: nil
        )
    }

    private func store(
        simpleFIN: StubSimpleFINTransport,
        enableBanking: StubEnableBankingTransport,
        linkSimpleFIN: Bool = true
    ) async throws -> LocalFirstActualStore {
        let bundle = try await EnableBankingTestSupport.makeStore(
            support: support, simpleFIN: simpleFIN, enableBanking: enableBanking
        )
        if linkSimpleFIN {
            try await bundle.store.bankSync.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")
        }
        try await EnableBankingTestSupport.link(bundle.store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)
        return bundle.store
    }

    @Test func backgroundSyncsBothProviders() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try EnableBankingTestSupport.download("booked-and-pending")),
        ])
        let store = try await store(simpleFIN: simpleFIN(response: simpleFINDownload()), enableBanking: enableBanking)

        let result = try await store.bankSync.backgroundBankSyncApply(request: .init(
            budgetID: "group-1", notificationID: nil, timeLimit: .seconds(20)
        ))

        #expect(result.accountCount == 2)
        #expect(result.insertedTransactionIDsByAccount["credit"]?.count == 4) // three rows and the opening balance
        #expect(result.insertedTransactionIDsByAccount["savings"]?.isEmpty == false)
        #expect(await enableBanking.statusRequests == 1)
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "credit") == "ok")
    }

    @Test(arguments: [false, true])
    func serverWithoutEnableBankingSkipsThoseAccountsForThisRun(probeFails: Bool) async throws {
        let enableBanking = StubEnableBankingTransport(
            ["eb-acct-checking": .success(try EnableBankingTestSupport.download("booked-and-pending"))],
            support: probeFails ? .failure(.transport(.timedOut)) : .success(.notConfigured)
        )
        let store = try await store(simpleFIN: simpleFIN(response: simpleFINDownload()), enableBanking: enableBanking)

        let result = try await store.bankSync.backgroundBankSyncApply(budgetID: "group-1")

        #expect(result.insertedTransactionIDsByAccount["savings"]?.isEmpty == false)
        #expect(result.insertedTransactionIDsByAccount["credit"] == nil)
        #expect(await enableBanking.requests.isEmpty)
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "credit") == nil)
    }

    @Test func enableBankingOnlyBudgetOnAServerWithoutItRefuses() async throws {
        let enableBanking = StubEnableBankingTransport(support: .success(.unsupported))
        let store = try await store(simpleFIN: simpleFIN(), enableBanking: enableBanking, linkSimpleFIN: false)

        await #expect(throws: BankSyncWorkflows.BankSyncStoreError.serverCannotBankSync) {
            try await store.bankSync.backgroundBankSyncApply(budgetID: "group-1")
        }
    }

    @Test func noLinkedAccountsOnAnEnableBankingServerIsNotARefusal() async throws {
        let enableBanking = StubEnableBankingTransport()
        let bundle = try await EnableBankingTestSupport.makeStore(
            support: support, simpleFIN: simpleFIN(support: .notConfigured), enableBanking: enableBanking
        )
        let result = try await bundle.store.bankSync.backgroundBankSyncApply(budgetID: "group-1")
        #expect(result.accountCount == 0)
        #expect(await enableBanking.statusRequests == 1)
    }

    /// Less time left than the apply needs: the Enable Banking accounts wait for the next run.
    @Test func shortTimeLimitLeavesTheEnableBankingAccountsForTheNextRun() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try EnableBankingTestSupport.download("booked-and-pending")),
        ])
        let store = try await store(simpleFIN: simpleFIN(response: simpleFINDownload()), enableBanking: enableBanking)

        let result = try await store.bankSync.backgroundBankSyncApply(request: .init(
            budgetID: "group-1", notificationID: nil,
            timeLimit: BankSyncWorkflows.backgroundApplyReserve - .seconds(1)
        ))

        #expect(await enableBanking.requests.isEmpty)
        #expect(result.insertedTransactionIDsByAccount["savings"]?.isEmpty == false)
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "credit") == nil)
    }

    @Test func simpleFINFailureStillAppliesTheEnableBankingAccountsThenReportsIt() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try EnableBankingTestSupport.download("booked-and-pending")),
        ])
        // The SimpleFIN status answers; its transactions route is missing.
        let store = try await store(simpleFIN: simpleFIN(response: nil), enableBanking: enableBanking)

        await #expect(throws: BankSyncWorkflows.BankSyncStoreError.notConfigured) {
            try await store.bankSync.backgroundBankSyncApply(budgetID: "group-1")
        }

        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "credit") == "ok")
        let run = try #require(try await store.bankSync.bankSyncLastRun(budgetID: "group-1"))
        #expect(run.trigger == .background)
        #expect(run.summary.hasSuffix(BankSyncRunTally.simpleFINNotSyncedNote))
    }
}
