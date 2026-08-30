import Foundation
import Testing
@testable import Actualist

/// Phase 4 view-model state machine (plan `simplefin-bank-sync-plan.md`):
/// idle → ready → downloading → reviewing → applying → done / failed, with
/// cancel writing nothing.
extension LocalFirstActualStoreTests {
    @MainActor
    private func makeViewModel(
        transport: StubSimpleFINTransport,
        linkSavings: Bool
    ) async throws -> (BankSyncViewModel, OpenedWritableStoreBundle) {
        let bundle = try await makeBankSyncStore(transport: transport)
        if linkSavings {
            try await bundle.store.linkBankAccount("savings", to: SimpleFINRemoteAccount(
                accountID: "sfin-1",
                name: "Checking",
                balance: "100.00",
                currency: "USD",
                institution: "Chase",
                orgName: "Chase",
                orgDomain: "chase.example",
                orgID: "org-1"
            ), budgetID: "group-1")
        }
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()
        return (model, bundle)
    }

    private func stubbedTransport(
        transactions: [SimpleFINRemoteTransaction],
        remoteAccounts: [SimpleFINRemoteAccount] = []
    ) -> StubSimpleFINTransport {
        StubSimpleFINTransport(
            remoteAccounts: remoteAccounts,
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

    @MainActor
    @Test func loadShowsLinkedAndUnlinkedRowsWithServerSupport() async throws {
        let transport = stubbedTransport(
            transactions: [],
            remoteAccounts: [SimpleFINRemoteAccount(
                accountID: "sfin-1",
                name: "Checking",
                balance: "1.00",
                currency: "USD",
                institution: nil,
                orgName: nil,
                orgDomain: "chase.example",
                orgID: nil
            )]
        )
        let (model, _) = try await makeViewModel(transport: transport, linkSavings: true)

        #expect(model.phase == .ready)
        #expect(model.serverSupport == .configured)
        let savings = try #require(model.accountLines.first { $0.id == "savings" })
        #expect(savings.isLinked)
        #expect(savings.isSyncable)
        #expect(savings.remoteAccountID == "sfin-1")
        #expect(savings.lastSyncText == "Never synced") // link never sets last_sync
        let credit = try #require(model.accountLines.first { $0.id == "credit" })
        #expect(!credit.isLinked)
        #expect(!credit.isSyncable)
        #expect(model.linkableRemoteAccounts.isEmpty) // the only remote is linked
    }

    @MainActor
    @Test func syncAllPresentsReviewThenConfirmAppliesAndFinishes() async throws {
        let transport = stubbedTransport(transactions: [
            SimpleFINRemoteTransaction(
                id: "d1",
                dateUnixSeconds: 1_782_974_400,
                amount: "-10.00",
                payeeName: "Coffee Shop",
                notes: "latte",
                booked: true,
                accountID: "sfin-1"
            )
        ])
        let (model, bundle) = try await makeViewModel(transport: transport, linkSavings: true)

        #expect(model.canSyncAll)
        await model.syncAll()
        #expect(model.phase == .reviewing)
        #expect(model.isReviewPresented)
        let line = try #require(model.reviewLines.first)
        #expect(line.accountName == "Savings")
        #expect(line.addedCount == 1)
        #expect(line.updatedCount == 0)

        await model.confirmReview()
        #expect(model.phase == .ready)
        #expect(!model.isReviewPresented)
        #expect(model.resultSummary?.contains("Added 1 transaction") == true)

        // The write really happened.
        let messages = try storedCRDTMessages(at: try bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(messages.contains {
            $0.dataset == "transactions" && $0.column == "financial_id" && $0.serializedValue == "S:d1"
        })
    }

    @MainActor
    @Test func cancelReviewWritesNothing() async throws {
        let transport = stubbedTransport(transactions: [
            SimpleFINRemoteTransaction(
                id: "d1",
                dateUnixSeconds: 1_782_974_400,
                amount: "-10.00",
                payeeName: "Coffee Shop",
                notes: nil,
                booked: true,
                accountID: "sfin-1"
            )
        ])
        let (model, bundle) = try await makeViewModel(transport: transport, linkSavings: true)

        await model.syncAll()
        #expect(model.phase == .reviewing)
        model.cancelReview()
        #expect(model.phase == .ready)
        #expect(model.reviewLines.isEmpty)

        let messages = try storedCRDTMessages(at: try bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains { $0.dataset == "transactions" && $0.column == "financial_id" })
    }

    @MainActor
    @Test func downloadFailureSurfacesFailedPhase() async throws {
        let transport = stubbedTransport(transactions: [])
        let (model, _) = try await makeViewModel(transport: transport, linkSavings: false)

        // Nothing is linked, so the download intent fails per account.
        await model.syncAll()
        guard case .failed = model.phase else {
            Issue.record("expected failed phase, got \(model.phase)")
            return
        }
        #expect(!model.isReviewPresented)
    }
}
