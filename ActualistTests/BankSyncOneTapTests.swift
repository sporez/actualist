import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

/// One-tap regressions that need the real store, its guarded SQLite writes,
/// and view-model state transitions in the same test.
extension LocalFirstActualStoreTests {
    @Test func oneTapPreflightsEveryAccountBeforeSavingAValidSibling() async throws {
        let firstRemote = oneTapRemoteAccount(id: "one-tap-1", name: "Checking")
        let secondRemote = oneTapRemoteAccount(id: "one-tap-2", name: "Savings")
        let transport = StubSimpleFINTransport(response: SimpleFINTransactionsResponse(
            downloads: [
                firstRemote.accountID: oneTapDownload(transactions: [
                    oneTapTransaction(
                        id: "valid-sibling",
                        remoteAccountID: firstRemote.accountID,
                        amount: "-4.00"
                    )
                ]),
                secondRemote.accountID: oneTapDownload(transactions: [
                    oneTapTransaction(
                        id: "unreadable-sibling",
                        remoteAccountID: secondRemote.accountID,
                        amount: nil
                    ),
                    oneTapTransaction(
                        id: "wrong-currency-sibling",
                        remoteAccountID: secondRemote.accountID,
                        amount: "-7.00",
                        currency: "EUR"
                    )
                ])
            ],
            errorType: nil,
            errorCode: nil
        ))
        let (model, bundle) = try await makeOneTapModel(
            transport: transport,
            links: [("checking", firstRemote), ("savings", secondRemote)]
        )

        await model.syncAll()

        guard case .failed = model.phase else {
            Issue.record("Expected whole-batch preflight to block the run")
            return
        }
        let validLine = try #require(model.resultLines.first { $0.id == "checking" })
        #expect(validLine.addedCount == 0)
        #expect(validLine.problemCount == 0)
        #expect(validLine.statusText == "Not saved")
        let blockedLine = try #require(model.resultLines.first { $0.id == "savings" })
        #expect(blockedLine.addedCount == 0)
        #expect(blockedLine.problemCount == 2)
        #expect(blockedLine.problemSummary?.contains("Unreadable amount") == true)
        #expect(blockedLine.problemSummary?.contains("Currency mismatch") == true)
        #expect(model.resultSummary == nil)
        #expect(try financialIDs(in: bundle).isEmpty)
        #expect((await transport.transactionsRequests).count == 1)
    }

    @Test func oneTapAppliesValidAccountAndReportsProviderErrorSiblingAsSkipped() async throws {
        let firstRemote = oneTapRemoteAccount(id: "one-tap-1", name: "Checking")
        let secondRemote = oneTapRemoteAccount(id: "one-tap-2", name: "Savings")
        let transport = StubSimpleFINTransport(response: SimpleFINTransactionsResponse(
            downloads: [
                firstRemote.accountID: oneTapDownload(transactions: [
                    oneTapTransaction(
                        id: "provider-valid",
                        remoteAccountID: firstRemote.accountID,
                        amount: "-4.00"
                    )
                ]),
                secondRemote.accountID: oneTapDownload(
                    transactions: [
                        oneTapTransaction(
                            id: "provider-row-must-not-save",
                            remoteAccountID: secondRemote.accountID,
                            amount: "-9.00"
                        )
                    ],
                    errorCode: "TIMED_OUT"
                )
            ],
            errorType: nil,
            errorCode: nil
        ))
        let (model, bundle) = try await makeOneTapModel(
            transport: transport,
            links: [("checking", firstRemote), ("savings", secondRemote)]
        )

        await model.syncAll()

        #expect(model.phase == .ready)
        #expect(model.resultSummary == "Synced 1 of 2 accounts. Added 1 transaction · 1 account skipped")
        let skipped = try #require(model.resultLines.first { $0.id == "savings" })
        #expect(skipped.addedCount == 0)
        #expect(skipped.statusText == "Skipped · Timed out")
        #expect(try financialIDs(in: bundle) == ["provider-valid"])
    }

    @Test func oneTapAllProviderErrorsNeverClaimsEverythingMatches() async throws {
        let remote = oneTapRemoteAccount(id: "one-tap-error", name: "Savings")
        let transport = StubSimpleFINTransport(response: SimpleFINTransactionsResponse(
            downloads: [
                remote.accountID: oneTapDownload(
                    transactions: [],
                    errorCode: "ACCOUNT_NEEDS_ATTENTION"
                )
            ],
            errorType: nil,
            errorCode: nil
        ))
        let (model, bundle) = try await makeOneTapModel(
            transport: transport,
            links: [("savings", remote)]
        )

        await model.syncAll()

        #expect(model.phase == .ready)
        #expect(model.resultSummary == "No accounts synced. 1 skipped.")
        #expect(model.resultSummary != "Everything already matches.")
        #expect(model.resultLines.first?.statusText == "Skipped · Needs attention")
        #expect(try financialIDs(in: bundle).isEmpty)
    }

    @Test func laterApplyFailureKeepsCommittedSummaryAndRetryIsIdempotent() async throws {
        let firstRemote = oneTapRemoteAccount(id: "one-tap-1", name: "Checking")
        let secondRemote = oneTapRemoteAccount(id: "one-tap-2", name: "Savings")
        let transport = StubSimpleFINTransport(
            remoteAccounts: [firstRemote, secondRemote],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    firstRemote.accountID: oneTapDownload(transactions: [
                        oneTapTransaction(
                            id: "committed-before-failure",
                            remoteAccountID: firstRemote.accountID,
                            amount: "-4.00"
                        )
                    ]),
                    secondRemote.accountID: oneTapDownload(
                        transactions: [
                            oneTapTransaction(
                                id: "rolled-back-second",
                                remoteAccountID: secondRemote.accountID,
                                amount: "-9.00"
                            )
                        ],
                        currentBalance: SimpleFINBalanceAmount(amount: "50.00", currency: "USD")
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let (model, bundle) = try await makeOneTapModel(
            transport: transport,
            links: [("checking", firstRemote), ("savings", secondRemote)]
        )
        let queue = try DatabaseQueue(
            path: bundle.fileManager.databaseURL(fileID: "file-1").path
        )
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_second_one_tap_apply
                BEFORE UPDATE OF bank_sync_status ON accounts
                WHEN OLD.id = 'savings'
                BEGIN SELECT RAISE(ABORT, 'synthetic second-account failure'); END
                """)
        }

        await model.syncAll()

        guard case .failed = model.phase else {
            Issue.record("Expected the second account apply to fail")
            return
        }
        #expect(model.resultSummary?.hasPrefix("Sync stopped after 1 of 2 accounts. ") == true)
        #expect(model.resultSummary?.contains("Added 1 transaction") == true)
        #expect(model.resultLines.map(\.id) == ["checking"])
        #expect(try financialIDs(in: bundle) == ["committed-before-failure"])
        #expect(try startingBalanceCount(in: bundle) == 0)

        try await queue.write { db in
            try db.execute(sql: "DROP TRIGGER reject_second_one_tap_apply")
        }
        await model.syncAll()

        #expect(model.phase == .ready)
        #expect(model.resultSummary?.contains("Added 1 transaction") == true)
        #expect(model.resultSummary?.contains("Added 1 opening balance") == true)
        #expect(try financialIDs(in: bundle) == [
            "committed-before-failure", "rolled-back-second"
        ])
        #expect(try startingBalanceCount(in: bundle) == 1)

        await model.syncAll()

        #expect(model.phase == .ready)
        #expect(model.resultSummary == "Everything already matches.")
        #expect(try financialIDs(in: bundle) == [
            "committed-before-failure", "rolled-back-second"
        ])
        #expect(try startingBalanceCount(in: bundle) == 1)
    }

    @Test func concurrentTapsAndLoadDuringDownloadStartOnlyOneRun() async throws {
        let remote = oneTapRemoteAccount(id: "one-tap-suspended", name: "Savings")
        let transport = SuspendedOneTapTransport(response: SimpleFINTransactionsResponse(
            downloads: [
                remote.accountID: oneTapDownload(transactions: [
                    oneTapTransaction(
                        id: "only-once",
                        remoteAccountID: remote.accountID,
                        amount: "-4.00"
                    )
                ])
            ],
            errorType: nil,
            errorCode: nil
        ))
        let (model, bundle) = try await makeOneTapModel(
            transport: transport,
            links: [("savings", remote)]
        )
        let primary = Task { @MainActor in await model.syncAll() }
        defer { transport.releaseTransactions() }
        do {
            try await transport.waitUntilTransactionRequested()
        } catch {
            primary.cancel()
            transport.releaseTransactions()
            await primary.value
            throw error
        }

        let repeatedTap = Task { @MainActor in await model.syncAll() }
        let anotherTap = Task { @MainActor in await model.syncAll() }
        let overlappingLoad = Task { @MainActor in await model.load() }
        await repeatedTap.value
        await anotherTap.value
        await overlappingLoad.value

        #expect(model.phase == .downloading)
        #expect(transport.transactionRequestCount == 1)
        transport.releaseTransactions()
        await primary.value

        #expect(model.phase == .ready)
        #expect(transport.transactionRequestCount == 1)
        #expect(try financialIDs(in: bundle) == ["only-once"])
    }

    @Test func cancelledDownloadCannotApplyItsCancellationInsensitiveResponse() async throws {
        let remote = oneTapRemoteAccount(id: "one-tap-cancelled", name: "Savings")
        let transport = SuspendedOneTapTransport(response: SimpleFINTransactionsResponse(
            downloads: [
                remote.accountID: oneTapDownload(transactions: [
                    oneTapTransaction(
                        id: "cancelled-late-row",
                        remoteAccountID: remote.accountID,
                        amount: "-4.00"
                    )
                ])
            ],
            errorType: nil,
            errorCode: nil
        ))
        let (model, bundle) = try await makeOneTapModel(
            transport: transport,
            links: [("savings", remote)]
        )
        let cancelledRun = Task { @MainActor in await model.syncAll() }
        defer { transport.releaseTransactions() }
        do {
            try await transport.waitUntilTransactionRequested()
        } catch {
            cancelledRun.cancel()
            transport.releaseTransactions()
            await cancelledRun.value
            throw error
        }

        cancelledRun.cancel()
        transport.releaseTransactions()
        await cancelledRun.value

        #expect(model.phase == .ready)
        #expect(model.resultLines.isEmpty)
        #expect(model.resultSummary == nil)
        #expect(try financialIDs(in: bundle).isEmpty)
        #expect(model.canSyncAll)

        await model.syncAll()

        #expect(model.phase == .ready)
        #expect(model.resultSummary == "Added 1 transaction")
        #expect(transport.transactionRequestCount == 2)
        #expect(try financialIDs(in: bundle) == ["cancelled-late-row"])
    }

    @Test func replacementSessionRejectsLateDownloadWithoutPublishingItsResult() async throws {
        let remote = oneTapRemoteAccount(id: "one-tap-retired", name: "Savings")
        let transport = SuspendedOneTapTransport(response: SimpleFINTransactionsResponse(
            downloads: [
                remote.accountID: oneTapDownload(transactions: [
                    oneTapTransaction(
                        id: "retired-session-row",
                        remoteAccountID: remote.accountID,
                        amount: "-4.00"
                    )
                ])
            ],
            errorType: nil,
            errorCode: nil
        ))
        let (retiredModel, bundle) = try await makeOneTapModel(
            transport: transport,
            links: [("savings", remote)]
        )
        let retiredRun = Task { @MainActor in await retiredModel.syncAll() }
        defer { transport.releaseTransactions() }
        do {
            try await transport.waitUntilTransactionRequested()
        } catch {
            retiredRun.cancel()
            transport.releaseTransactions()
            await retiredRun.value
            throw error
        }

        bundle.store.closeOpenBudget()
        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        bundle.store.openedServerURLString = "https://sync.example"
        let replacementModel = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await replacementModel.load()
        #expect(replacementModel.phase == .ready)
        #expect(replacementModel.canSyncAll)

        transport.releaseTransactions()
        await retiredRun.value

        #expect(retiredModel.phase == .downloading)
        #expect(retiredModel.resultLines.isEmpty)
        #expect(retiredModel.resultSummary == nil)
        #expect(try financialIDs(in: bundle).isEmpty)

        await replacementModel.syncAll()

        #expect(replacementModel.phase == .ready)
        #expect(replacementModel.resultSummary == "Added 1 transaction")
        #expect(transport.transactionRequestCount == 2)
        #expect(try financialIDs(in: bundle) == ["retired-session-row"])
    }

    private func makeOneTapModel(
        transport: any SimpleFINServerTransport,
        links: [(localAccountID: String, remote: SimpleFINRemoteAccount)]
    ) async throws -> (BankSyncViewModel, OpenedWritableStoreBundle) {
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            simpleFINTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [],
            additionalFixtureSQL: Self.bankSyncColumnsSQL + """
                CREATE TABLE IF NOT EXISTS preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT OR REPLACE INTO preferences VALUES ('defaultCurrencyCode', 'USD');
                """
        )
        bundle.store.openedServerURLString = "https://sync.example"
        try bundle.keychain.saveActualSyncToken("one-tap-sync-token")
        for link in links {
            try await bundle.store.linkBankAccount(
                link.localAccountID,
                to: link.remote,
                budgetID: "group-1"
            )
        }
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.canSyncAll)
        return (model, bundle)
    }

    private func oneTapRemoteAccount(
        id: String,
        name: String
    ) -> SimpleFINRemoteAccount {
        SimpleFINRemoteAccount(
            accountID: id,
            name: name,
            balance: nil,
            currency: "USD",
            institution: nil,
            orgName: "Synthetic Bank",
            orgDomain: "synthetic.example",
            orgID: nil
        )
    }

    private func oneTapTransaction(
        id: String,
        remoteAccountID: String,
        amount: String?,
        currency: String? = "USD"
    ) -> SimpleFINRemoteTransaction {
        SimpleFINRemoteTransaction(
            id: id,
            dateUnixSeconds: 1_782_993_600,
            amount: amount,
            currency: currency,
            payeeName: "One Tap Payee",
            notes: nil,
            booked: true,
            accountID: remoteAccountID
        )
    }

    private func oneTapDownload(
        transactions: [SimpleFINRemoteTransaction],
        currentBalance: SimpleFINBalanceAmount? = nil,
        errorCode: String? = nil
    ) -> SimpleFINAccountDownload {
        SimpleFINAccountDownload(
            transactions: transactions,
            currentBalance: currentBalance,
            startingBalance: nil,
            errorType: errorCode.map { _ in "provider_error" },
            errorCode: errorCode
        )
    }

    private func financialIDs(in bundle: OpenedWritableStoreBundle) throws -> [String] {
        try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
            .filter { $0.dataset == "transactions" && $0.column == "financial_id" }
            .map { String($0.serializedValue.dropFirst(2)) }
            .sorted()
    }

    private func startingBalanceCount(in bundle: OpenedWritableStoreBundle) throws -> Int {
        try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
            .filter { message in
                message.dataset == "transactions"
                    && message.column == "starting_balance_flag"
                    && message.serializedValue == "N:1"
            }
            .count
    }
}

private final class SuspendedOneTapTransport: SimpleFINServerTransport, Sendable {
    private struct State: Sendable {
        var transactionRequestCount = 0
    }

    private let response: SimpleFINTransactionsResponse
    private let state = Mutex(State())
    private let transactionRequested = TestLatch()
    private let transactionsReleased = TestLatch()

    init(response: SimpleFINTransactionsResponse) {
        self.response = response
    }

    var transactionRequestCount: Int {
        state.withLock { $0.transactionRequestCount }
    }

    func simpleFINStatus(token: String) async throws -> SimpleFINServerSupport {
        .configured
    }

    func simpleFINAccounts(token: String) async throws -> [SimpleFINRemoteAccount]? {
        []
    }

    func simpleFINTransactions(
        token: String,
        accountIDs: [String],
        startDates: [String]
    ) async throws -> SimpleFINTransactionsResponse? {
        state.withLock { $0.transactionRequestCount += 1 }
        transactionRequested.trip()
        // Intentionally ignores task cancellation until the test releases the
        // provider, matching a late network callback that still returns data.
        await transactionsReleased.wait()
        return response
    }

    func waitUntilTransactionRequested() async throws {
        try await waitForOneTapLatch(
            transactionRequested,
            description: "SimpleFIN transaction request"
        )
    }

    func releaseTransactions() {
        transactionsReleased.trip()
    }
}

private struct OneTapLatchTimeout: LocalizedError {
    let description: String

    var errorDescription: String? {
        "Timed out waiting for \(description)."
    }
}

private func waitForOneTapLatch(
    _ latch: TestLatch,
    description: String
) async throws {
    let reached = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            try await withTaskCancellationHandler {
                await latch.wait()
                try Task.checkCancellation()
                return true
            } onCancel: {
                latch.trip()
            }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            return false
        }
        defer { group.cancelAll() }
        let first = try await group.next() ?? false
        if !first {
            // Release the cancellation-insensitive latch waiter before leaving
            // the task group; the caller releases and awaits the operation.
            latch.trip()
        }
        group.cancelAll()
        return first
    }
    guard reached else {
        throw OneTapLatchTimeout(description: description)
    }
}
