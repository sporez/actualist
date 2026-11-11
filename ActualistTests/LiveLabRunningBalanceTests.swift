import Foundation
import GRDB
import Testing
@testable import Actualist

/// Opt-in live check that the running-balance setting round-trips with a real
/// Actual client (the Node peer in `scripts/parity/live-lab-interop/`, step
/// `runningBalanceCheck`). Order: `runningBalancePrepare()`,
/// `run.sh runningBalanceCheck`, `runningBalanceVerifyRemoteOff()`. Needs the
/// `LiveLab` variables and `ACTUAL_LAB_RUNNING_BALANCE=1`.
@Suite(.serialized, .enabled(if: LiveLab.isConfigured && ProcessInfo.processInfo.environment["ACTUAL_LAB_RUNNING_BALANCE"] == "1"))
@MainActor
struct LiveLabRunningBalanceTests {
    private func makeSignedInStore() async throws -> LocalFirstActualStore {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LiveLabRunningBalance-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = LiveLab.makeStore(root: root)
        _ = try await LiveLab.signIn(store)
        return store
    }

    private func open(_ fileID: String, in store: LocalFirstActualStore) async throws -> ActualBudget {
        let serverURL = try #require(LiveLab.url)
        let budget = try #require(try await store.loadBudgets(serverURLString: serverURL).first { $0.cloudFileId == fileID })
        try await store.openBudget(budget, serverURLString: serverURL)
        return budget
    }

    private func accountID(named name: String, in database: BudgetDatabase) async throws -> String {
        let queue = await database.queue
        return try #require(try await queue.read {
            try String.fetchOne($0, sql: "SELECT id FROM accounts WHERE name = ? AND tombstone = 0", arguments: [name])
        })
    }

    private func feedSetting(_ store: LocalFirstActualStore, _ database: BudgetDatabase, budgetID: String, accountID: String) async throws -> Bool? {
        try await store.loadedAccountTransactions(
            database: database, budgetID: budgetID, accountID: accountID, query: TransactionFeedQuery()
        ).runningBalanceSetting
    }

    @Test func runningBalancePrepare() async throws {
        let store = try await makeSignedInStore()
        let serverURL = try #require(LiveLab.url)
        let creation = try await store.createNewBudget(
            named: "Interop Check running-balance \(UUID().uuidString.prefix(6))", serverURLString: serverURL
        )
        let budget = try await open(creation.fileID, in: store)
        try await store.createAccountAndRefresh(budgetID: budget.syncID, name: "Balance Checking", offbudget: false)
        let database = try store.requireDatabase(for: budget.syncID)
        let accountID = try await accountID(named: "Balance Checking", in: database)
        try await store.setShowsRunningBalance(budgetID: budget.syncID, accountID: accountID, enabled: true)
        #expect(try await feedSetting(store, database, budgetID: budget.syncID, accountID: accountID) == true)
        try await store.refresh(budgetID: budget.syncID, serverURLString: serverURL)
        let queue = await database.queue
        let queued = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? -1 }
        #expect(queued == 0)
        try LiveLab.writeHandoff("running-balance.json", [
            "fileID": creation.fileID, "accountID": accountID, "outboxCount": queued,
        ])
    }

    @Test func runningBalanceVerifyRemoteOff() async throws {
        let handoff = try LiveLab.readHandoff("running-balance.json")
        let fileID = try #require(handoff["fileID"] as? String)
        let accountID = try #require(handoff["accountID"] as? String)
        let store = try await makeSignedInStore()
        let budget = try await open(fileID, in: store)
        try await store.refresh(budgetID: budget.syncID, serverURLString: try #require(LiveLab.url))
        let database = try store.requireDatabase(for: budget.syncID)
        let setting = try await feedSetting(store, database, budgetID: budget.syncID, accountID: accountID)
        try LiveLab.writeHandoff("running-balance-actualist.json", ["settingAfterRemoteOff": setting.map { $0 as Any } ?? NSNull()])
        #expect(setting == false)
    }
}
