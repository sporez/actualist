import Foundation
import GRDB
import Testing
@testable import Actualist

/// Opt-in live interop checks against a disposable Actual server. Every test is
/// skipped unless `ACTUAL_LAB_URL` and `ACTUAL_LAB_PASSWORD` are present in the
/// test process environment (xcodebuild forwards `TEST_RUNNER_*` variables with
/// the prefix stripped), so ordinary unit runs never touch the network.
///
/// `ACTUAL_LAB_HANDOFF_DIR` names a host directory shared with the Node peer in
/// `scripts/parity/live-lab-interop/`. Nothing here records the URL or the
/// password; only file IDs, ids and counts are written. See that README.
enum LiveLab {
    static let environment = ProcessInfo.processInfo.environment
    static var url: String? { environment["ACTUAL_LAB_URL"].flatMap { $0.isEmpty ? nil : $0 } }
    static var password: String? { environment["ACTUAL_LAB_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 } }
    static var handoffDirectory: URL? {
        environment["ACTUAL_LAB_HANDOFF_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var isConfigured: Bool { url != nil && password != nil && handoffDirectory != nil }

    static func writeHandoff(_ name: String, _ value: [String: Any]) throws {
        let directory = try #require(handoffDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appending(path: name), options: .atomic)
    }

    static func readHandoff(_ name: String) throws -> [String: Any] {
        let directory = try #require(handoffDirectory)
        let data = try Data(contentsOf: directory.appending(path: name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Wraps the production sync client and counts `/sync/sync` requests so a test
/// can report how many round trips a pull needed.
private final class CountingSyncTransport: ActualSyncTransport, @unchecked Sendable {
    private let inner: any ActualSyncTransport
    private let counter: SyncRequestCounter

    init(inner: any ActualSyncTransport, counter: SyncRequestCounter) {
        self.inner = inner
        self.counter = counter
    }

    func sync(data: Data, token: String) async throws -> Data {
        counter.increment()
        return try await inner.sync(data: data, token: token)
    }
}

private final class SyncRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite(.serialized, .enabled(if: LiveLab.isConfigured))
struct LiveLabInteropTests {
    // MARK: Fixtures

    @MainActor
    private func makeStore(
        root: URL,
        counter: SyncRequestCounter = SyncRequestCounter()
    ) -> LocalFirstActualStore {
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: FakeKeychainBackend()
        )
        let fileManager = BudgetFileManager(applicationSupportURL: root)
        return LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: { url in
                CountingSyncTransport(
                    inner: ActualServerSyncClient(baseURL: url),
                    counter: counter
                )
            }
        )
    }

    @MainActor
    private func signIn(_ store: LocalFirstActualStore) async throws -> StagedLocalFirstConnection {
        let staged = try await store.stageConnection(
            serverURLString: try #require(LiveLab.url),
            password: try #require(LiveLab.password),
            selectedBudgetID: nil
        )
        try store.commitConnection(staged)
        return staged
    }

    private func persistentRoot() throws -> URL {
        try #require(LiveLab.handoffDirectory).appending(path: "swift-root", directoryHint: .isDirectory)
    }

    /// The trie hash Actualist persists in `messages_clock` (`merkle.hash`).
    @MainActor
    private func merkleHash(of store: LocalFirstActualStore, fileID: String) throws -> Int? {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: store.fileManager.databaseURL(fileID: fileID).path,
            configuration: configuration
        )
        let clock = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT clock FROM messages_clock ORDER BY id LIMIT 1")
        }
        guard let data = clock?.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let merkle = object["merkle"] as? [String: Any] else { return nil }
        return merkle["hash"] as? Int
    }

    @MainActor
    private func snapshot(of store: LocalFirstActualStore) async throws -> [[String: Any]] {
        let database = try #require(store.database)
        let transactions = try await database.fetchTransactions()
        return transactions
            .sorted { ($0.id ?? "") < ($1.id ?? "") }
            .map { transaction in
                [
                    "id": transaction.id ?? "",
                    "amount": transaction.amount ?? 0,
                    "category": transaction.category ?? "",
                    "account": transaction.account,
                ]
            }
    }

    // MARK: Check 1: New Budget

    /// Creates a New Budget through the production flow (starter seed, portable
    /// archive, registration upload) under a unique `Interop Check` name.
    @MainActor
    @Test func createNewBudgetOnLab() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LiveLab-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let before = try await signIn(store).budgets.count
        let name = "Interop Check \(UUID().uuidString.prefix(8))"
        let creation = try await store.createNewBudget(
            named: name,
            serverURLString: try #require(LiveLab.url)
        )
        let after = try await store.loadBudgets(serverURLString: try #require(LiveLab.url))
        let listed = after.first { $0.cloudFileId == creation.fileID }
        try LiveLab.writeHandoff("newbudget.json", [
            "fileID": creation.fileID,
            "groupID": creation.groupID ?? "",
            "name": name,
        ])
        print("LIVELAB new-budget fileID=\(creation.fileID) name=\(name) budgetsBefore=\(before) budgetsAfter=\(after.count)")
        #expect(listed != nil)
        #expect(creation.groupID?.isEmpty == false)
    }

    // MARK: Check 2: two-client merkle convergence

    /// Phase A: open the budget a Node peer has already written to, sync, make
    /// a local transaction, sync again. A second Node client then pushes older
    /// timestamps (see the README) before phase B.
    @MainActor
    @Test func mergePhaseAOpenWriteSync() async throws {
        let seed = try LiveLab.readHandoff("peer-seed.json")
        let fileID = try #require(seed["fileID"] as? String)
        let accountID = try #require(seed["accountID"] as? String)
        let categoryID = try #require(seed["categoryID"] as? String)
        let counter = SyncRequestCounter()
        let root = try persistentRoot()
        try? FileManager.default.removeItem(at: root)
        let store = makeStore(root: root, counter: counter)
        let staged = try await signIn(store)
        let budget = try #require(staged.budgets.first { $0.cloudFileId == fileID })
        let serverURL = try #require(LiveLab.url)

        try await store.openBudget(budget, serverURLString: serverURL)
        let requestsAfterOpen = counter.count
        let afterOpen = try await snapshot(of: store)

        let draft = TransactionDraft(
            accountID: accountID,
            date: Date(),
            amountMinorUnits: -4242,
            payeeID: nil,
            payeeName: "Swift Local Payee",
            categoryID: categoryID,
            notes: "swift-local",
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(draft, budgetID: budget.syncID) {}
        try await store.refresh(budgetID: budget.syncID, serverURLString: serverURL)
        let afterWrite = try await snapshot(of: store)
        let hash = try merkleHash(of: store, fileID: fileID)
        try LiveLab.writeHandoff("swift-phase-a.json", [
            "createdTransactionID": created.changed.transactions.first ?? "",
            "requestsAfterOpen": requestsAfterOpen,
            "requestsTotal": counter.count,
            "transactionsAfterOpen": afterOpen,
            "transactionsAfterWrite": afterWrite,
            "merkleHash": hash as Any,
        ])
        print("LIVELAB phaseA requestsAfterOpen=\(requestsAfterOpen) requestsTotal=\(counter.count) txAfterOpen=\(afterOpen.count) txAfterWrite=\(afterWrite.count) merkle=\(String(describing: hash))")
        #expect(afterWrite.count == afterOpen.count + 1)
    }

    /// Phase B: reopen the same local budget and sync. Messages the second Node
    /// client pushed carry timestamps older than this file's newest, so only the
    /// merkle re-pull can bring them in.
    @MainActor
    @Test func mergePhaseBResync() async throws {
        let seed = try LiveLab.readHandoff("peer-seed.json")
        let fileID = try #require(seed["fileID"] as? String)
        let counter = SyncRequestCounter()
        let store = makeStore(root: try persistentRoot(), counter: counter)
        let staged = try await signIn(store)
        let budget = try #require(staged.budgets.first { $0.cloudFileId == fileID })
        let serverURL = try #require(LiveLab.url)

        // Opening pulls: the requests counted here are the pull's round trips.
        try await store.openBudget(budget, serverURLString: serverURL)
        let requestsAfterOpen = counter.count
        try await store.refresh(budgetID: budget.syncID, serverURLString: serverURL)
        let after = try await snapshot(of: store)
        let hash = try merkleHash(of: store, fileID: fileID)
        try LiveLab.writeHandoff("swift-phase-b.json", [
            "requestsAfterOpen": requestsAfterOpen,
            "requestsTotal": counter.count,
            "transactions": after,
            "merkleHash": hash as Any,
        ])
        print("LIVELAB phaseB requestsAfterOpen=\(requestsAfterOpen) requestsTotal=\(counter.count) txFinal=\(after.count) merkle=\(String(describing: hash))")
    }
}
