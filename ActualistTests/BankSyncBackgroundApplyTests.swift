import Foundation
import Testing
@testable import Actualist

/// Phase 6 store tests: the background SimpleFIN step applies linked
/// accounts through the server connection only and reports inserted IDs.
extension LocalFirstActualStoreTests {
    private func backgroundTransport(
        support: SimpleFINServerSupport = .configured,
        transactionCount: Int = 1
    ) -> StubSimpleFINTransport {
        let transactions = (0..<transactionCount).map { index in
            SimpleFINRemoteTransaction(
                id: "bg-\(index)",
                dateUnixSeconds: 1_783_000_000,
                amount: "-10.00",
                currency: "USD",
                payeeName: "Background Payee",
                notes: nil,
                booked: true,
                accountID: "sfin-1"
            )
        }
        return StubSimpleFINTransport(
            support: support,
            remoteAccounts: [
                SimpleFINRemoteAccount(
                    accountID: "sfin-1",
                    name: "Checking",
                    balance: "100.00",
                    currency: "USD",
                    institution: nil,
                    orgName: "Chase",
                    orgDomain: "chase.example",
                    orgID: "org-1"
                )
            ],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: transactions,
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
    }

    @Test func backgroundApplyInsertsAndReportsIDsThenIsIdempotent() async throws {
        let transport = backgroundTransport()
        let bundle = try await makeBankSyncStore(transport: transport)
        try await bundle.store.linkBankAccount("savings", to: SimpleFINRemoteAccount(
            accountID: "sfin-1",
            name: "Checking",
            balance: "100.00",
            currency: "USD",
            institution: nil,
            orgName: "Chase",
            orgDomain: "chase.example",
            orgID: "org-1"
        ), budgetID: "group-1")

        let first = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(first.accountCount == 1)
        // One download + one opening balance (100.00 − (−10.00)).
        #expect(first.insertedTransactionIDsByAccount["savings"]?.count == 2)
        #expect(await transport.accountsRequests == 1)

        let second = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(second.accountCount == 1)
        #expect(second.insertedTransactionIDsByAccount["savings"]?.isEmpty != false)
        // Once the account has local history, balance metadata is not needed
        // for opening-balance math and no second account-list request is made.
        #expect(await transport.accountsRequests == 1)
    }

    @Test func backgroundPreflightsEveryBatchedPlanBeforeFirstApply() async throws {
        let firstRemote = SimpleFINRemoteAccount(
            accountID: "sfin-1",
            name: "Savings",
            balance: "0.00",
            currency: "USD",
            institution: nil,
            orgName: "Bank",
            orgDomain: "bank.example",
            orgID: nil
        )
        let secondRemote = SimpleFINRemoteAccount(
            accountID: "sfin-2",
            name: "Credit",
            balance: "0.00",
            currency: "USD",
            institution: nil,
            orgName: "Bank",
            orgDomain: "bank.example",
            orgID: nil
        )
        let transport = StubSimpleFINTransport(
            remoteAccounts: [firstRemote, secondRemote],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [SimpleFINRemoteTransaction(
                            id: "would-apply",
                            dateUnixSeconds: 1_783_000_000,
                            amount: "-10.00",
                            currency: "USD",
                            payeeName: "Valid",
                            notes: nil,
                            booked: true,
                            accountID: "sfin-1"
                        )],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    ),
                    "sfin-2": SimpleFINAccountDownload(
                        transactions: [SimpleFINRemoteTransaction(
                            id: "bad",
                            dateUnixSeconds: 1_783_000_000,
                            amount: nil,
                            currency: "USD",
                            payeeName: "Unreadable",
                            notes: nil,
                            booked: true,
                            accountID: "sfin-2"
                        )],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(transport: transport)
        try await bundle.store.linkBankAccount("savings", to: firstRemote, budgetID: "group-1")
        try await bundle.store.linkBankAccount("credit", to: secondRemote, budgetID: "group-1")

        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        }

        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.column == "financial_id"
        })
        #expect((await transport.transactionsRequests).count == 1)
    }

    @Test func backgroundApplySkipsUnlinkedAccounts() async throws {
        let bundle = try await makeBankSyncStore(transport: backgroundTransport())
        let result = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(result.accountCount == 0)
        #expect(result.insertedTransactionIDsByAccount.isEmpty)
    }

    @Test func backgroundApplyRefusesWhenServerCannotServeAndNeverReadsDeviceKey() async throws {
        let bundle = try await makeBankSyncStore(
            transport: backgroundTransport(support: .notConfigured)
        )
        // A stored Phase 5 device key must NOT be promoted to background use.
        try bundle.keychain.saveSimpleFINAccessURL("https://user:secret@bridge.example/user")
        #expect(bundle.store.hasBankSyncDeviceKey())

        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.serverCannotBankSync) {
            try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        }
    }
}
