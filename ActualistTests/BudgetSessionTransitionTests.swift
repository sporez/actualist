import Foundation
import Observation
import SwiftProtobuf
import Testing
@testable import Actualist

/// Competing budget opens join or are refused instead of cancelling each
/// other into spurious failures.
@MainActor
struct BudgetSessionTransitionTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func doubleSelectOfOneBudgetOpensOnceAndBothCallersSeeOpened() async throws {
        let bundle = try await syncingBundle()
        let appState = try readyAppState(for: bundle)
        let target = try installCachedBudget(in: bundle, fileID: "file-2", groupID: "group-2")
        let probe = OpenProbe(store: bundle.store)

        let first = Task { await appState.selectBudgetForCurrentBackend(target) }
        await probe.parked.wait()
        let second = Task { await appState.selectBudgetForCurrentBackend(target) }
        await probe.waitForSecondRequest(appState)
        probe.release()

        #expect(await first.value == .opened)
        #expect(await second.value == .opened)
        #expect(probe.openCount == 1)
        #expect(appState.settings.selectedBudgetID == "group-2")
        #expect(bundle.store.isOpen(budgetID: "group-2"))
        #expect(appState.isReadyForMainTabs)
    }

    @Test func launchRestoreJoinsAShortcutOpeningTheSameBudget() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        bundle.store.reset()
        let probe = OpenProbe(store: bundle.store)

        let intent = Task { try await ShortcutsBudgetSession(appState: appState).prepare() }
        await probe.parked.wait()
        let restore = Task { await appState.beginForegroundSession() }
        await probe.waitForSecondRequest(appState)
        probe.release()

        let prepared = try await intent.value
        await restore.value
        #expect(prepared.budgetID == "group-1")
        #expect(probe.openCount == 1)
        #expect(appState.setupPhase == .ready)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
    }

    @Test func selectingAnotherBudgetDuringASwitchIsRefusedAsBusy() async throws {
        let bundle = try await syncingBundle()
        let appState = try readyAppState(for: bundle)
        let budgetB = try installCachedBudget(in: bundle, fileID: "file-2", groupID: "group-2")
        let budgetC = try installCachedBudget(in: bundle, fileID: "file-3", groupID: "group-3")
        let probe = OpenProbe(store: bundle.store)

        let toB = Task { await appState.selectBudgetForCurrentBackend(budgetB) }
        await probe.parked.wait()
        let toC = await appState.selectBudgetForCurrentBackend(budgetC)
        probe.release()

        #expect(toC == .busy)
        #expect(await toB.value == .opened)
        #expect(appState.settings.selectedBudgetID == "group-2")
        #expect(bundle.store.isOpen(budgetID: "group-2"))
    }

    @Test func launchRestoreDoesNotCancelABackgroundPullOfTheSameBudget() async throws {
        let gate = StubConnectionWaitGate()
        let transport = FirstPullGatedTransport(gate: gate)
        let bundle = try await fixtures.makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        bundle.store.reset()
        let appState = try fixtures.makeAppState(for: bundle)
        appState.settings.backgroundTransactionRefreshEnabled = true
        #expect(appState.setupPhase == .restoringBudget)

        let background = Task { await appState.performBackgroundTransactionRefresh() }
        await gate.waitForEntry()
        await appState.beginForegroundSession()
        #expect(appState.setupPhase == .ready)
        await gate.release()

        #expect(await background.value)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let run = try #require(appState.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
    }

    @Test func reimportIsRefusedWhileAnotherBudgetOpens() async throws {
        let bundle = try await syncingBundle()
        let appState = try readyAppState(for: bundle)
        let target = try installCachedBudget(in: bundle, fileID: "file-2", groupID: "group-2")
        let probe = OpenProbe(store: bundle.store)

        let select = Task { await appState.selectBudgetForCurrentBackend(target) }
        await probe.parked.wait()
        let reimport = await appState.reimportLocalFirstBudget()
        probe.release()

        #expect(reimport == .busy)
        #expect(await select.value == .opened)
    }

    @Test func shortcutOpenOfAMissingFileFailsAndFreesTheCoordinator() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        bundle.store.reset()
        try bundle.fileManager.deleteImportedBudget(fileID: "file-1")

        await #expect(throws: ShortcutsError.budgetFileMissing) {
            try await ShortcutsBudgetSession(appState: appState).prepare()
        }
        #expect(!appState.budgetSessionTransitions.isTransitionInFlight)
    }

    @Test func eraseCancelsAnInFlightSwitch() async throws {
        let bundle = try await syncingBundle()
        let appState = try readyAppState(for: bundle)
        let target = try installCachedBudget(in: bundle, fileID: "file-2", groupID: "group-2")
        let probe = OpenProbe(store: bundle.store)

        let select = Task { await appState.selectBudgetForCurrentBackend(target) }
        await probe.parked.wait()
        await appState.disconnectAndEraseLocalData()
        #expect(!appState.budgetSessionTransitions.isTransitionInFlight)
        probe.release()

        #expect(await select.value == .superseded)
        #expect(appState.setupPhase == .needsConnection)
        #expect(!bundle.store.hasOpenBudget)
    }

    /// Selecting a cached budget pulls after the open, so it needs a token
    /// and a transport that answers.
    @Test func storeCancellationDuringLaunchRestoreIsSupersededWithoutDiscovery() async throws {
        let server = StubConnectionTransport(files: [fixtures.testRemoteFile()])
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in server }
        )
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try fixtures.makeAppState(for: bundle)
        bundle.store.reset()
        let probe = OpenProbe(store: bundle.store)

        let restore = Task { await appState.beginForegroundSession() }
        await probe.parked.wait()
        // A teardown outside the recovery identity cancels the parked open.
        bundle.store.closeOpenBudget()
        probe.release()
        await restore.value

        #expect(await server.listUserFilesRequestCount == 0)
        #expect(appState.setupPhase == .restoringBudget)
        #expect(appState.lastErrorMessage == nil)
    }

    private func syncingBundle() async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle { _ in RecordingSyncTransport() }
        try bundle.keychain.saveActualSyncToken("token")
        return bundle
    }

    private func readyAppState(for bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> AppState {
        let appState = try fixtures.makeAppState(for: bundle)
        appState.selectedBudget = bundle.budget
        appState.setupPhase = .ready
        appState.connectionStatus = .online
        return appState
    }

    private func installCachedBudget(
        in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle, fileID: String, groupID: String
    ) throws -> ActualBudget {
        let directory = try bundle.fileManager.budgetDirectory(fileID: fileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: bundle.fileManager.databaseURL(fileID: "file-1"),
            to: bundle.fileManager.databaseURL(fileID: fileID)
        )
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID, cloudFileID: fileID, groupID: groupID,
            budgetName: "Budget \(groupID)", encryptionKeyID: nil, nodeID: "node\(fileID.suffix(1))"
        )
        try JSONEncoder.actual.encode(metadata).write(to: bundle.fileManager.metadataURL(fileID: fileID))
        return ActualBudget(budgetID: fileID, cloudFileId: fileID, groupId: groupID, name: "Budget \(groupID)", state: nil)
    }
}

/// Parks the first budget open after its database is installed; later opens
/// pass through and are counted, so a test can tell a join from a reopen.
@MainActor
@Observable
private final class OpenProbe {
    @ObservationIgnored let parked = TestLatch()
    private(set) var openCount = 0
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Never>?

    init(store: LocalFirstActualStore) {
        store.seams.budgetOpenSuspension = { [weak self] in
            guard let self else { return }
            openCount += 1
            guard openCount == 1 else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                parked.trip()
            }
        }
    }

    /// Before the fix the second request reopens the budget; after it, the
    /// request waits on the coordinator. Either way it has acted.
    func waitForSecondRequest(_ appState: AppState) async {
        await ObservedTestState {
            self.openCount > 1 || appState.budgetSessionTransitions.waitingRequestCount > 0
        }.wait()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Holds the first pull until released; later syncs answer at once.
private actor FirstPullGatedTransport: ActualSyncTransport {
    let gate: StubConnectionWaitGate
    private var calls = 0

    init(gate: StubConnectionWaitGate) {
        self.gate = gate
    }

    func sync(data: Data, token: String) async throws -> Data {
        calls += 1
        if calls == 1 { await gate.wait() }
        return try ActualSync_SyncResponse().serializedData()
    }
}
