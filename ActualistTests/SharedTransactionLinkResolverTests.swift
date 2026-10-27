import Foundation
import Testing
@testable import Actualist

@MainActor
struct SharedTransactionLinkResolverTests {
    private let context = TransactionEditorSession.Context(budgetID: "budget", serverURL: "")

    @Test func aLocalHitOpensWithoutSyncing() async {
        let source = FakeSharedTransactionSource(lookups: [.found(transaction("txn"))])
        let resolver = SharedTransactionLinkResolver()

        let resolved = await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source)

        #expect(resolved?.id == "txn")
        #expect(source.syncCount == 0)
        #expect(source.lookedUp == ["budget/txn"])
        #expect(resolver.state == .idle)
    }

    @Test func aLocalMissWaitsForOneSyncThenOpens() async {
        let gate = TestLatch()
        let source = FakeSharedTransactionSource(lookups: [.missing, .found(transaction("txn"))], syncGate: gate)
        let resolver = SharedTransactionLinkResolver()

        let resolving = Task { await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source) }
        await source.syncStarted.wait()
        #expect(resolver.state == .syncing)
        gate.trip()

        #expect(await resolving.value?.id == "txn")
        #expect(source.syncCount == 1)
        #expect(source.lookedUp == ["budget/txn", "budget/txn"])
        #expect(resolver.state == .idle)
    }

    @Test func stillMissingAfterASuccessfulSyncIsNotOnThisDevice() async {
        let source = FakeSharedTransactionSource(lookups: [.missing, .missing])
        let resolver = SharedTransactionLinkResolver()

        #expect(await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source) == nil)
        #expect(resolver.state == .failed(.notOnDevice))
        resolver.dismissFailure()
        #expect(resolver.state == .idle)
    }

    @Test func stillMissingAfterAFailedSyncSaysTheServerWasUnreachable() async {
        let source = FakeSharedTransactionSource(lookups: [.missing, .missing], syncSucceeds: false)
        let resolver = SharedTransactionLinkResolver()

        #expect(await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source) == nil)
        #expect(resolver.state == .failed(.serverUnreachable))
    }

    @Test func aFailedSyncStillOpensATransactionThatArrived() async {
        let source = FakeSharedTransactionSource(lookups: [.missing, .found(transaction("txn"))], syncSucceeds: false)
        let resolver = SharedTransactionLinkResolver()

        #expect(await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source)?.id == "txn")
    }

    @Test func aDeletedRowSaysSoWithoutSyncing() async {
        let source = FakeSharedTransactionSource(lookups: [.deleted])
        let resolver = SharedTransactionLinkResolver()

        #expect(await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source) == nil)
        #expect(resolver.state == .failed(.deleted))
        #expect(source.syncCount == 0)
    }

    @Test func aReadErrorIsReportedAsUnreadable() async {
        let source = FakeSharedTransactionSource(lookups: [], failsLookup: true)
        let resolver = SharedTransactionLinkResolver()

        #expect(await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source) == nil)
        #expect(resolver.state == .failed(.unreadable))
    }

    @Test func cancellingDuringTheSyncDropsTheResult() async {
        let gate = TestLatch()
        let source = FakeSharedTransactionSource(lookups: [.missing, .found(transaction("txn"))], syncGate: gate)
        let resolver = SharedTransactionLinkResolver()

        let resolving = Task { await resolver.resolve(transactionID: "txn", budgetID: "budget", source: source) }
        await source.syncStarted.wait()
        #expect(resolver.state == .syncing)
        resolver.cancel()
        gate.trip()

        #expect(await resolving.value == nil)
        #expect(resolver.state == .idle)
    }

    @Test func aNewerLinkReplacesOneStillSyncing() async {
        let gate = TestLatch()
        let older = FakeSharedTransactionSource(lookups: [.missing, .found(transaction("old"))], syncGate: gate)
        let newer = FakeSharedTransactionSource(lookups: [.found(transaction("new"))])
        let resolver = SharedTransactionLinkResolver()

        let first = Task { await resolver.resolve(transactionID: "old", budgetID: "budget", source: older) }
        await older.syncStarted.wait()
        let second = await resolver.resolve(transactionID: "new", budgetID: "budget", source: newer)
        gate.trip()

        #expect(second?.id == "new")
        #expect(await first.value == nil)
        #expect(resolver.state == .idle)
    }

    @Test func presenterOpensTheResolvedTransactionInTheEditor() async throws {
        let presenter = RootTransactionEditorPresenter()
        let source = FakeSharedTransactionSource(lookups: [.found(transaction("txn"))])

        await presenter.openSharedTransaction(id: "txn", context: context, source: source) { context }

        let session = try #require(presenter.presentation)
        #expect(session.model.isEditing)
        #expect(session.context == context)
    }

    @Test func presenterWaitsForAnOpenEditorToClose() async throws {
        let presenter = RootTransactionEditorPresenter()
        #expect(presenter.present(context: context))
        let creating = try #require(presenter.presentation)
        let source = FakeSharedTransactionSource(lookups: [.found(transaction("txn"))])

        await presenter.openSharedTransaction(id: "txn", context: context, source: source) { context }
        #expect(presenter.presentation === creating)

        presenter.presentation = nil
        #expect(presenter.presentPendingSharedEdit(currentContext: context))
        #expect(presenter.presentation?.model.isEditing == true)
        #expect(!presenter.presentPendingSharedEdit(currentContext: context))
    }

    @Test func presenterDropsALinkResolvedForABudgetNoLongerOpen() async {
        let presenter = RootTransactionEditorPresenter()
        let source = FakeSharedTransactionSource(lookups: [.found(transaction("txn"))])
        let other = TransactionEditorSession.Context(budgetID: "other", serverURL: "")

        await presenter.openSharedTransaction(id: "txn", context: context, source: source) { other }

        #expect(presenter.presentation == nil)
        #expect(!presenter.presentPendingSharedEdit(currentContext: context))
    }

    private func transaction(_ id: String) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
            date: "2026-10-20",
            amount: -8412,
            payee: "payee",
            payeeName: "Synthetic Payee",
            importedPayee: nil,
            category: "groceries",
            notes: nil,
            cleared: nil
        )
    }
}

@MainActor
private final class FakeSharedTransactionSource: SharedTransactionLinkSource {
    private var lookups: [SharedTransactionLookup]
    private let syncSucceeds: Bool
    private let failsLookup: Bool
    private let syncGate: TestLatch?
    let syncStarted = TestLatch()
    private(set) var syncCount = 0
    private(set) var lookedUp: [String] = []

    init(
        lookups: [SharedTransactionLookup],
        syncSucceeds: Bool = true,
        failsLookup: Bool = false,
        syncGate: TestLatch? = nil
    ) {
        self.lookups = lookups
        self.syncSucceeds = syncSucceeds
        self.failsLookup = failsLookup
        self.syncGate = syncGate
    }

    func lookUpSharedTransaction(budgetID: String, id: String) async throws -> SharedTransactionLookup {
        lookedUp.append("\(budgetID)/\(id)")
        if failsLookup { throw CocoaError(.fileReadCorruptFile) }
        return lookups.isEmpty ? .missing : lookups.removeFirst()
    }

    func syncForSharedTransaction(budgetID: String) async -> Bool {
        syncCount += 1
        syncStarted.trip()
        if let syncGate { await syncGate.wait() }
        return syncSucceeds
    }
}
