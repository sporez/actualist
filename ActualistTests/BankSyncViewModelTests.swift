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
        linkSavings: Bool,
        additionalFixtureSQL: String = ""
    ) async throws -> (BankSyncViewModel, OpenedWritableStoreBundle) {
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: additionalFixtureSQL
        )
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
                orgName: "Friendly Bank",
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
        #expect(model.linkedAccountDisplayName(for: savings) == "Checking")
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

        let savings = try #require(model.accountLines.first { $0.id == "savings" })
        #expect(model.linkedAccountDisplayName(for: savings) == "Savings")
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
    @Test func matchedReviewDisclosesEveryPlannedFieldWrite() async throws {
        let transport = stubbedTransport(transactions: [
            SimpleFINRemoteTransaction(
                id: "bank-match",
                dateUnixSeconds: 1_782_993_600,
                amount: "-10.00",
                payeeName: "Coffee Shop",
                notes: "bank memo",
                booked: true,
                accountID: "sfin-1"
            )
        ])
        let (model, bundle) = try await makeViewModel(
            transport: transport,
            linkSavings: true,
            additionalFixtureSQL: """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                     description, notes, cleared)
                VALUES
                    ('local-match', 'savings', 20260702, -1000, 'groceries', 0, NULL, 0,
                     'coffee', '', 0);
                """
        )

        await model.syncAll()

        let line = try #require(model.reviewLines.first)
        #expect(line.updatedCount == 1)
        let match = try #require(line.matchLines.first)
        #expect(match.title == "Coffee Shop")
        #expect(match.dateText == "2026-07-02")
        #expect(match.changes == [
            "Attach bank transaction ID",
            "Bank payee: None → “Coffee Shop”",
            "Notes: None → “bank memo”",
            "Cleared: No → Yes"
        ])

        await model.confirmReview()
        let messages = try storedCRDTMessages(
            at: try bundle.fileManager.databaseURL(fileID: "file-1")
        ).filter { $0.dataset == "transactions" && $0.row == "local-match" }
        #expect(Set(messages.map { "\($0.column)=\($0.serializedValue)" }) == [
            "financial_id=S:bank-match",
            "imported_description=S:Coffee Shop",
            "notes=S:bank memo",
            "cleared=N:1"
        ])
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
    @Test func reviewWithNormalizationProblemsCannotConfirm() async throws {
        let transport = stubbedTransport(transactions: [
            SimpleFINRemoteTransaction(
                id: "bad-amount",
                dateUnixSeconds: 1_782_974_400,
                amount: nil,
                payeeName: "Unreadable",
                notes: nil,
                booked: true,
                accountID: "sfin-1"
            )
        ])
        let (model, _) = try await makeViewModel(transport: transport, linkSavings: true)

        await model.syncAll()
        #expect(model.phase == .reviewing)
        #expect(model.reviewLines.first?.problemCount == 1)
        #expect(model.reviewLines.first?.problemSummary == "1× Unreadable amount")
        #expect(model.reviewHasProblems)
        #expect(!model.canConfirmReview)
        await model.confirmReview()
        #expect(model.phase == .reviewing)
    }

    @MainActor
    @Test func backgroundSyncCopyReflectsServerCapability() {
        #expect(BankSyncCopy.backgroundSyncFooter(
            support: nil,
            phase: .loading,
            isDemoMode: false
        ) == "Checking your server…")
        #expect(BankSyncCopy.backgroundSyncFooter(
            support: .unsupported,
            phase: .ready,
            isDemoMode: false
        ).contains("Device-only tokens are not used"))
        #expect(BankSyncCopy.backgroundSyncFooter(
            support: .configured,
            phase: .ready,
            isDemoMode: false
        ).contains("downloaded and saved automatically"))
    }

    @MainActor
    @Test func remoteAccountFailureIsNotPresentedAsAnEmptyList() async throws {
        let transport = StubSimpleFINTransport(
            accountsFailure: ActualAPIError.decoding
        )
        let bundle = try await makeBankSyncStore(transport: transport)
        let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)

        await model.load()

        guard case .failed(let message) = model.phase else {
            Issue.record("expected account metadata failure, got \(model.phase)")
            return
        }
        #expect(message == "Actualist could not read the server response.")
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

// MARK: - Phase 5/6 follow-up: device key survives a failed server probe

extension LocalFirstActualStoreTests {
    @MainActor
    @Test func failedServerProbeStillSurfacesStoredDeviceKey() async throws {
        let transport = StubSimpleFINTransport(failure: ActualAPIError.transport(URLError.Code.timedOut))
        let bundle = try await makeBankSyncStore(transport: transport)
        // A claimed device token exists, but the server probe throws.
        try bundle.keychain.saveSimpleFINAccessURL("https://user:secret@bridge.example/user")

        let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)
        await model.load()

        #expect(model.phase == .ready)
        #expect(model.hasDeviceKey)
        #expect(model.canLinkAccounts)
        // The device-token provider text is shown, not "Not connected".
        #expect(BankSyncCopy.providerText(support: model.serverSupport, hasDeviceKey: model.hasDeviceKey, isDemoMode: false)
            == "SimpleFIN via a device token")
    }
}
