import Foundation
import Testing
@testable import Actualist

/// A round that applied remote messages and then failed keeps their side
/// effects: caches reload and a background run reports the pulled
/// transactions. The error, the outbox and cancellation behave as before.
extension LocalFirstActualStoreTests {
    private static let partialPhantom = "2026-07-04T11:00:00.000Z-0000-0000000000000099"

    private func partialStore(
        failingWith error: (any Error)? = nil
    ) async throws -> (OpenedWritableStoreBundle, MerkleAwareSyncTransport) {
        let server = MerkleAwareSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle(syncTransportFactory: { _ in server })
        try bundle.keychain.saveActualSyncToken("token")
        await bundle.store.syncClient.configure(LocalFirstSyncConfiguration(
            fileID: "file-1", groupID: "group-1", nodeID: "node1", encryptionKeyID: nil, encryptionContext: nil
        ))
        try await bundle.store.refreshAccountsWithBalances(budgetID: "group-1")
        let timestamp = "2026-07-04T12:00:00.000Z-0000-00000000000000cc"
        let cells = [("acct", "S:savings"), ("date", "N:20260704"), ("amount", "N:-4321"), ("tombstone", "N:0")]
        try await server.seed(cells.enumerated().map { index, cell in
            ActualSyncDecodedMessage(
                timestamp: timestamp.replacingOccurrences(of: "-0000-", with: "-000\(index)-"),
                dataset: "transactions", row: "remote-tx", column: cell.0, serializedValue: cell.1
            )
        })
        // A server timestamp no client can supply: every round ends `syncOutOfSync`.
        await server.addPhantom(Self.partialPhantom)
        return (bundle, server)
    }

    private func savingsBalance(_ bundle: OpenedWritableStoreBundle) -> Int? {
        bundle.store.accountDisplays(budgetID: "group-1").first { $0.id == "savings" }?.balance
    }

    @Test func aRefreshThatFailsAfterApplyingStillReloadsTheCaches() async throws {
        let (bundle, _) = try await partialStore()

        await #expect(throws: LocalFirstError.syncOutOfSync) {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }

        #expect(savingsBalance(bundle) == -4321)
        #expect(bundle.store.syncStatus?.lastError != nil)
    }

    @Test func aBackgroundRefreshThatFailsAfterApplyingReportsThePulledTransaction() async throws {
        let (bundle, _) = try await partialStore()

        let failure = await #expect(throws: BackgroundRefreshPartialFailure.self) {
            _ = try await bundle.store.syncAndFindNewTransactions(
                budget: bundle.budget, serverURLString: "https://sync.example", openBudget: { _ in true }
            )
        }

        let partial = try #require(failure)
        #expect(partial.underlying as? LocalFirstError == .syncOutOfSync)
        #expect(partial.results.flatMap(\.newTransactionIDs) == ["remote-tx"])
        #expect(savingsBalance(bundle) == -4321)
    }

    @Test func aCancelledRoundThatAppliedMessagesDoesNotReload() async throws {
        let (bundle, server) = try await partialStore()
        // The first request applies the transaction; cancel before the next round.
        await server.setOnRequest { request in
            if request == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }

        // The refresh runs in its own task, so the hook cancels it and not the test.
        let store = bundle.store
        let refresh = Task { try await store.refresh(budgetID: "group-1", serverURLString: "https://sync.example") }
        let outcome = await refresh.result

        #expect(outcome.isCancellationFailure)
        #expect(savingsBalance(bundle) != -4321)
    }

    @Test func aFailureBeforeAnythingIsAppliedReportsTheRawError() async throws {
        let (bundle, server) = try await partialStore()
        await server.setOnRequest { _ in throw URLError(.notConnectedToInternet) }

        let failure = await #expect(throws: (any Error).self) {
            _ = try await bundle.store.syncAndFindNewTransactions(
                budget: bundle.budget, serverURLString: "https://sync.example", openBudget: { _ in true }
            )
        }

        #expect(!(failure is BackgroundRefreshPartialFailure))
        #expect(savingsBalance(bundle) != -4321)
    }
}

@MainActor
struct PartialSyncApplyRecorderTests {
    private func applied(_ count: Int, ids: [String: [String]] = [:]) -> BudgetDatabase.RemoteSyncApplyResult {
        BudgetDatabase.RemoteSyncApplyResult(appliedMessageCount: count, insertedTransactionIDsByAccount: ids)
    }

    @Test func settlingNotesTheIDsAndReloadsOnce() async {
        let recorder = PartialSyncApplyRecorder()
        await recorder.record(applied(2, ids: ["a": ["t1"]]))
        await recorder.record(applied(1, ids: ["a": ["t2"], "b": ["t3"]]))
        let lane = ServerSyncLane()
        let token = lane.beginBackgroundRun()
        var reloads = 0

        await PartialSyncApply.settleAfterFailure(recorder, lane: lane) { reloads += 1 }

        #expect(reloads == 1)
        #expect(lane.endBackgroundRun(token) == ["a": ["t1", "t2"], "b": ["t3"]])
    }

    @Test func settlingAfterNothingWasAppliedDoesNothing() async {
        let recorder = PartialSyncApplyRecorder()
        await recorder.record(applied(0))
        let lane = ServerSyncLane()
        let token = lane.beginBackgroundRun()
        var reloads = 0

        await PartialSyncApply.settleAfterFailure(recorder, lane: lane) { reloads += 1 }

        #expect(reloads == 0)
        #expect(lane.endBackgroundRun(token).isEmpty)
    }

    @Test func aFailingReloadStillNotesTheIDs() async {
        let recorder = PartialSyncApplyRecorder()
        await recorder.record(applied(1, ids: ["a": ["t1"]]))
        let lane = ServerSyncLane()
        let token = lane.beginBackgroundRun()

        await PartialSyncApply.settleAfterFailure(recorder, lane: lane) { throw CancellationError() }

        #expect(lane.endBackgroundRun(token) == ["a": ["t1"]])
    }

    @Test func anEndedSessionsLaneDropsTheIDs() async {
        let recorder = PartialSyncApplyRecorder()
        await recorder.record(applied(1, ids: ["a": ["t1"]]))
        let lane = ServerSyncLane()
        let token = lane.beginBackgroundRun()
        lane.invalidate()

        await PartialSyncApply.settleAfterFailure(recorder, lane: lane) {}

        #expect(lane.endBackgroundRun(token).isEmpty)
    }
}

private extension Result where Success == Void, Failure == any Error {
    var isCancellationFailure: Bool {
        if case .failure(let error) = self { return error.isCancellation }
        return false
    }
}
