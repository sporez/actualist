import Foundation
import Testing
@testable import Actualist

/// One-tap Bank Sync through the real local store and synthetic providers.
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
    @Test func bankCancellationLeavesLoadsAndDownloadsRetryable() async throws {
        let transport = StubSimpleFINTransport(accountsFailure: .transport(.cancelled))
        let (model, bundle) = try await makeViewModel(transport: transport, linkSavings: true)
        await model.ensureRemoteAccounts()
        #expect(model.remoteAccountsStatus == .idle)
        await transport.setFailure(.transport(.cancelled))
        await model.syncAll()
        #expect(model.phase == .ready)
        #expect(model.resultLines.isEmpty)
        #expect(model.canSyncAll)
        try bundle.keychain.saveSimpleFINAccessURL("https://test:test@bridge.example/user")
        do {
            _ = try await bundle.store.bankSyncProvider(budgetID: "group-1")
            Issue.record("Cancellation must not fall back to the device provider")
        } catch { #expect(error.isCancellation) }
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
        #expect(model.remoteAccountsStatus == .idle)
        let savings = try #require(model.accountLines.first { $0.id == "savings" })
        #expect(savings.isLinked)
        #expect(savings.isSyncable)
        #expect(savings.remoteAccountID == "sfin-1")
        #expect(savings.lastSyncText == "Never synced") // link never sets last_sync
        let credit = try #require(model.accountLines.first { $0.id == "credit" })
        #expect(!credit.isLinked)
        #expect(!credit.isSyncable)
        #expect(credit.lastSyncText == "Not linked")
        #expect(credit.statusColorKind == .none)

        await model.ensureRemoteAccounts()
        #expect(model.remoteAccountsStatus == .ready)
        #expect(model.linkedAccountDisplayName(for: savings) == "Checking")
        #expect(model.linkableRemoteAccounts.isEmpty) // the only remote is linked
    }

    @MainActor
    @Test func syncAllAppliesAndFinishesWithoutConfirmation() async throws {
        let transport = stubbedTransport(transactions: [
            SimpleFINRemoteTransaction(
                id: "d1",
                dateUnixSeconds: 1_782_974_400,
                amount: "-10.00",
                currency: "USD",
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
        let line = try #require(model.resultLines.first)
        #expect(line.accountName == "Savings")
        #expect(line.addedCount == 1)
        #expect(line.updatedCount == 0)

        #expect(model.phase == .ready)
        #expect(model.lastRun?.summary.contains("Added 1 transaction") == true)

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
                currency: "USD",
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

        let line = try #require(model.resultLines.first)
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
    @Test func repeatingSyncAllIsIdempotent() async throws {
        let transport = stubbedTransport(transactions: [
            SimpleFINRemoteTransaction(
                id: "d1",
                dateUnixSeconds: 1_782_974_400,
                amount: "-10.00",
                currency: "USD",
                payeeName: "Coffee Shop",
                notes: nil,
                booked: true,
                accountID: "sfin-1"
            )
        ])
        let (model, bundle) = try await makeViewModel(transport: transport, linkSavings: true)

        await model.syncAll()
        #expect(model.lastRun?.summary == "Added 1 transaction")
        await model.syncAll()
        #expect(model.phase == .ready)
        #expect(model.lastRun?.summary == "Everything already matches.")

        let messages = try storedCRDTMessages(at: try bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(messages.filter { $0.dataset == "transactions" && $0.column == "financial_id" }.count == 1)
    }

    @MainActor
    @Test func normalizationProblemsBlockOneTapApplyAndRemainVisible() async throws {
        let transport = stubbedTransport(transactions: [
            SimpleFINRemoteTransaction(
                id: "bad-amount",
                dateUnixSeconds: 1_782_974_400,
                amount: nil,
                currency: "USD",
                payeeName: "Unreadable",
                notes: nil,
                booked: true,
                accountID: "sfin-1"
            )
        ])
        let (model, bundle) = try await makeViewModel(transport: transport, linkSavings: true)

        await model.syncAll()
        guard case .failed = model.phase else { Issue.record("Expected blocked run"); return }
        #expect(model.resultLines.first?.problemCount == 1)
        #expect(model.resultLines.first?.problemSummary == "1× Unreadable amount")
        #expect(model.resultLines.first?.addedCount == 0)
        #expect(model.canSyncAll)
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains { $0.dataset == "transactions" })
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
    @Test func loadEnablesSyncAllWithoutFetchingRemoteAccounts() async throws {
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
        #expect(model.canSyncAll)
        #expect(model.remoteAccountsStatus == .idle)
        #expect(await transport.statusRequests == 1)
        #expect(await transport.accountsRequests == 0)

        await model.ensureRemoteAccounts()
        #expect(model.remoteAccountsStatus == .ready)
        #expect(await transport.statusRequests == 1)
        #expect(await transport.accountsRequests == 1)
    }

    @MainActor
    @Test func cachedSupportKeepsSyncEnabledWhenRefreshFails() async throws {
        let transport = stubbedTransport(transactions: [])
        let (model, _) = try await makeViewModel(transport: transport, linkSavings: true)
        #expect(model.canSyncAll)
        #expect(model.serverSupport == .configured)

        await transport.setFailure(.transport(URLError.Code.timedOut))
        await model.load()

        #expect(model.phase == .ready)
        #expect(model.canSyncAll)
        #expect(model.serverSupport == .configured)
    }

    @MainActor
    @Test func remoteAccountFailureIsNotPresentedAsAnEmptyList() async throws {
        let transport = StubSimpleFINTransport(
            accountsFailure: ActualAPIError.decoding
        )
        let bundle = try await makeBankSyncStore(transport: transport)
        let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)

        await model.load()
        #expect(model.phase == .ready)
        #expect(model.remoteAccountsStatus == .idle)

        await model.ensureRemoteAccounts()
        guard case .failed(let message) = model.remoteAccountsStatus else {
            Issue.record("expected account metadata failure, got \(model.remoteAccountsStatus)")
            return
        }
        #expect(message == "Actualist could not read the server response.")
        #expect(model.phase == .ready)
        #expect(model.linkableRemoteAccounts.isEmpty)
    }

    @MainActor
    @Test func noLinkedAccountsDoesNotStartDownload() async throws {
        let transport = stubbedTransport(transactions: [])
        let (model, _) = try await makeViewModel(transport: transport, linkSavings: false)

        #expect(!model.canSyncAll)
        await model.syncAll()
        #expect(model.phase == .ready)
        #expect(model.lastRun?.summary == nil)
        #expect(await transport.transactionsRequests.isEmpty)
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

    @Test func lastRunCaptionNamesTheTriggerAndAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manual = BankSyncLastRun(finishedAt: now.addingTimeInterval(-10), trigger: .manual, summary: "")
        let background = BankSyncLastRun(
            finishedAt: now.addingTimeInterval(-3 * 3_600),
            trigger: .background,
            summary: ""
        )
        #expect(BankSyncCopy.lastRunCaption(manual, now: now) == "Sync All · just now")
        #expect(BankSyncCopy.lastRunCaption(background, now: now) == "Background sync · 3h ago")
    }
}
