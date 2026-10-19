import Foundation
import Testing
@testable import Actualist

/// Opt-in live check against the disposable lab server: an outbox larger than
/// one upload batch, and a local edit during an upload, each converge in one
/// sync. Each case creates its own `Interop Check` budget and records its file
/// ID and expected payee count in `sync-batch.json`; the Node peer step
/// `syncBatchCheck` (`scripts/parity/live-lab-interop/`) downloads each with
/// Actual's client, compares the count and deletes it. Needs the `LiveLab`
/// variables and `ACTUAL_LAB_SYNC_BATCH=1`.
/// Runs `hook` while each request is in flight, to commit a local edit during it.
private final class EditDuringRequestTransport: ActualSyncTransport, @unchecked Sendable {
    // Invariant: `calls` and `storedHook` are read and written only under `lock`.
    private let inner: ActualServerSyncClient
    private let lock = NSLock()
    private var calls = 0
    private var storedHook: (@Sendable (Int) async throws -> Void)?

    init(inner: ActualServerSyncClient) { self.inner = inner }

    var hook: (@Sendable (Int) async throws -> Void)? {
        get { lock.withLock { storedHook } }
        set { lock.withLock { storedHook = newValue } }
    }

    func sync(data: Data, token: String) async throws -> Data {
        let (call, hook) = lock.withLock { () -> (Int, (@Sendable (Int) async throws -> Void)?) in
            calls += 1
            return (calls, storedHook)
        }
        async let response = inner.sync(data: data, token: token)
        try await hook?(call)
        return try await response
    }
}

@Suite(.serialized, .enabled(if: LiveLab.isConfigured && ProcessInfo.processInfo.environment["ACTUAL_LAB_SYNC_BATCH"] == "1"))
struct LiveLabSyncBatchTests {
    @MainActor
    private func openFreshBudget(
        _ label: String,
        transport: EditDuringRequestTransport? = nil
    ) async throws -> (LocalFirstActualStore, ActualBudget, BudgetDatabase) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SyncDiag-\(UUID().uuidString)", directoryHint: .isDirectory)
        var factory: (@Sendable (URL) -> any ActualSyncTransport)?
        if let transport {
            factory = { (_: URL) -> any ActualSyncTransport in transport }
        }
        let store = LiveLab.makeStore(root: root, syncTransportFactory: factory)
        _ = try await LiveLab.signIn(store)
        let serverURL = try #require(LiveLab.url)
        let name = "Interop Check \(label) \(UUID().uuidString.prefix(6))"
        let creation = try await store.createNewBudget(named: name, serverURLString: serverURL)
        try recordBudget(label, ["fileID": creation.fileID, "name": name])
        let budget = try #require(try await store.loadBudgets(serverURLString: serverURL)
            .first { $0.cloudFileId == creation.fileID })
        try await store.openBudget(budget, serverURLString: serverURL)
        return (store, budget, try store.requireDatabase(for: budget.syncID))
    }

    private func commitPayees(_ count: Int, prefix: String, to database: BudgetDatabase) async throws {
        _ = try await database.commitLocalSyncMessagesAndEnqueue((0..<count).map { index in
            ActualSyncDecodedMessage(
                timestamp: "pending", dataset: "payees", row: UUID().uuidString, column: "name",
                serializedValue: "S:Diag \(prefix) \(index)"
            )
        })
    }

    @MainActor
    private func refresh(_ store: LocalFirstActualStore, _ budget: ActualBudget) async -> String {
        do {
            try await store.refresh(budgetID: budget.syncID, serverURLString: try #require(LiveLab.url))
            return "ok"
        } catch {
            return String(describing: error)
        }
    }

    /// Merges `values` into the case's entry in `sync-batch.json`.
    private func recordBudget(_ label: String, _ values: [String: Any]) throws {
        var record = (try? LiveLab.readHandoff("sync-batch.json")) ?? [:]
        record[label] = (record[label] as? [String: Any] ?? [:]).merging(values) { _, new in new }
        try LiveLab.writeHandoff("sync-batch.json", record)
    }

    @MainActor
    @Test(arguments: [500, 501])
    func outboxOf(_ count: Int) async throws {
        let label = "n\(count)"
        let (store, budget, database) = try await openFreshBudget(label)
        try await commitPayees(count, prefix: label, to: database)
        let outcome = await refresh(store, budget)
        let pending = try await database.pendingLocalSyncMessageCount()
        try recordBudget(label, ["expectedPayees": count, "outcome": outcome, "pending": pending])
        #expect(outcome == "ok")
        #expect(pending == 0)
    }

    @MainActor
    @Test func oneSyncUploadsSixteenHundred() async throws {
        let label = "n1600"
        let (store, budget, database) = try await openFreshBudget(label)
        try await commitPayees(1_600, prefix: label, to: database)
        let outcome = await refresh(store, budget)
        let pending = try await database.pendingLocalSyncMessageCount()
        try recordBudget(label, ["expectedPayees": 1_600, "outcome": outcome, "pending": pending])
        #expect(outcome == "ok")
        #expect(pending == 0)
    }

    @MainActor
    @Test func editDuringUpload() async throws {
        let label = "editDuringUpload"
        let transport = EditDuringRequestTransport(inner: ActualServerSyncClient(baseURL: URL(string: try #require(LiveLab.url))!))
        let (store, budget, database) = try await openFreshBudget(label, transport: transport)
        try await commitPayees(1, prefix: "first", to: database)
        // Only the first sync after the hook is set: the upload of "first".
        let fired = SyncDiagFlag()
        transport.hook = { _ in
            guard await fired.claim() else { return }
            try await commitPayees(1, prefix: "during", to: database)
        }
        let outcome = await refresh(store, budget)
        let pending = try await database.pendingLocalSyncMessageCount()
        try recordBudget(label, ["expectedPayees": 2, "outcome": outcome, "pending": pending])
        #expect(outcome == "ok")
        #expect(pending == 0)
    }
}

private actor SyncDiagFlag {
    private var used = false
    func claim() -> Bool {
        defer { used = true }
        return !used
    }
}
