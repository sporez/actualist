import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    private static let balanceAccount = ActualAccount(
        id: "checking", name: "Checking", offbudget: false, closed: false
    )
    private static let balanceKey = "show-balances-checking"

    private func pendingCells(_ bundle: OpenedWritableStoreBundle) async throws -> [String] {
        try await bundle.store.database?.pendingLocalSyncMessages().map {
            "\($0.message.dataset)|\($0.message.row)|\($0.message.column)|\($0.message.serializedValue)"
        } ?? []
    }

    @Test func runningBalanceWriteQueuesOnlyTheValueCellAndShowsBalances() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);"
        )
        let store = bundle.store
        let model = AccountTransactionsViewModel(scope: .account(Self.balanceAccount))
        await model.loadLocal(budgetID: "group-1", repository: store)
        func rows() -> [AccountTransactionRowPresentation] {
            model.displayState(
                budgetID: "group-1", repository: store,
                pendingNewTransactionIDs: [], privacyModeEnabled: false
            ).groups.flatMap(\.rows)
        }
        #expect(rows().allSatisfy { $0.runningBalanceText == nil })

        try await store.setShowsRunningBalance(budgetID: "group-1", accountID: "checking", enabled: true)

        #expect(try await pendingCells(bundle) == ["preferences|\(Self.balanceKey)|value|S:true"])
        let shown = rows()
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { $0.runningBalanceText != nil })
        #expect(try await bundle.store.database?.recentBudgetActions().isEmpty == true)

        try await store.setShowsRunningBalance(budgetID: "group-1", accountID: "checking", enabled: false)

        #expect(rows().allSatisfy { $0.runningBalanceText == nil })
        #expect(try await pendingCells(bundle).suffix(1) == ["preferences|\(Self.balanceKey)|value|S:false"])
    }

    @Test func runningBalanceWriteOfTheCurrentValueWritesAndReloadsNothing() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('\(Self.balanceKey)', 'true');
            """)
        let store = bundle.store
        try await store.refreshTransactions(
            budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()
        )
        let before = store.cachedTransactions(
            budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()
        )
        #expect(before?.runningBalanceSetting == true)

        try await store.setShowsRunningBalance(budgetID: "group-1", accountID: "checking", enabled: true)

        #expect(try await pendingCells(bundle).isEmpty)
        #expect(store.cachedTransactions(
            budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()
        ) == before)
    }

    @Test func newPreferenceRowWithTombstoneColumnQueuesTheTombstoneCellToo() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER);
            """)

        try await bundle.store.setShowsRunningBalance(budgetID: "group-1", accountID: "checking", enabled: true)

        #expect(Set(try await pendingCells(bundle)) == [
            "preferences|\(Self.balanceKey)|value|S:true",
            "preferences|\(Self.balanceKey)|tombstone|N:0",
        ])
    }

    @Test func runningBalanceWriteWithoutPreferencesTableThrowsAndQueuesNothing() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()

        await #expect(throws: LocalFirstError.self) {
            try await bundle.store.setShowsRunningBalance(
                budgetID: "group-1", accountID: "checking", enabled: true
            )
        }
        #expect(try await pendingCells(bundle).isEmpty)
    }
}
