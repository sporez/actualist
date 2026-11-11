import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct AccountTransactionRunningBalanceProjectionTests {
    private static let account = ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)

    private static func page(
        _ rows: [ActualTransaction],
        balance: Int? = 1_000,
        setting: Bool? = true,
        query: TransactionFeedQuery = TransactionFeedQuery(),
        withMetadata: Bool = true
    ) -> LoadedAccountTransactions {
        LoadedAccountTransactions(
            transactions: rows, balance: balance, categoryNames: [:], payeeNames: [:],
            transferPayeeIDs: [], reachedEnd: true,
            queryMetadata: withMetadata ? TransactionQueryPageMetadata(
                totalMatchCount: rows.count, querySignature: query.signature,
                matchingTransactionIDs: [], contributingTransactionIDs: [],
                attachedContextTransactionIDs: []) : nil,
            runningBalanceSetting: setting
        )
    }

    private static func state(
        _ page: LoadedAccountTransactions?,
        scope: TransactionFeedScope = .account(account),
        statusFilter: TransactionStatusFilter = .all,
        query: String = "",
        privacy: Bool = false
    ) -> AccountTransactionsDisplayState {
        AccountTransactionFeedProjection(
            scope: scope, loaded: page, activePage: page, statusFilter: statusFilter, query: query,
            pendingNewTransactionIDs: [], privacyModeEnabled: privacy
        ).displayState
    }

    private static func rows(_ state: AccountTransactionsDisplayState) -> [AccountTransactionRowPresentation] {
        state.groups.flatMap(\.rows)
    }

    private static let sample = [
        AccountRunningBalancesTests.row("a", -300, date: "2026-08-21"),
        AccountRunningBalancesTests.row("b", 1_000, date: "2026-08-20"),
        AccountRunningBalancesTests.row("c", -200, date: "2026-08-19")
    ]

    @Test func settingOnShowsBalancesWithTones() {
        let state = Self.state(Self.page(Self.sample, balance: 500))
        let rows = Self.rows(state)
        #expect(state.showsRunningBalances)
        #expect(state.runningBalanceSetting == true)
        #expect(rows.map(\.runningBalanceText) == [
            BudgetCurrency.usd.formatted(500), BudgetCurrency.usd.formatted(800), BudgetCurrency.usd.formatted(-200)
        ])
        #expect(rows.map(\.runningBalanceTone) == [.positive, .positive, .negative])
    }

    @Test func zeroBalanceHasZeroTone() {
        let rows = Self.rows(Self.state(Self.page([AccountRunningBalancesTests.row("a", 0)], balance: 0)))
        #expect(rows.first?.runningBalanceTone == .zero)
    }

    @Test func olderPageAppendedContinuesSequence() {
        let first = Self.page(Array(Self.sample.prefix(2)), balance: 500)
        let older = Self.page([Self.sample[2]], balance: 9_999)
        let merged = first.appendingPage(older)
        #expect(merged.balance == 500)
        #expect(merged.runningBalanceSetting == true)
        let rows = Self.rows(Self.state(merged))
        #expect(rows.last?.runningBalanceText == BudgetCurrency.usd.formatted(-200))
    }

    @Test func gateIsOffWhenSettingIsNotTrueOrBalanceUnknown() {
        for page in [
            Self.page(Self.sample, setting: false),
            Self.page(Self.sample, setting: nil),
            Self.page(Self.sample, balance: nil)
        ] {
            let state = Self.state(page)
            #expect(!state.showsRunningBalances)
            #expect(Self.rows(state).allSatisfy { $0.runningBalanceText == nil && $0.runningBalanceTone == nil })
        }
        #expect(Self.state(Self.page(Self.sample, setting: false)).runningBalanceSetting == false)
        #expect(Self.state(Self.page(Self.sample, setting: nil)).runningBalanceSetting == nil)
    }

    @Test func gateIsOffForFilteredOrSearchedQueriesAndMissingMetadata() {
        let queries = [
            TransactionFeedQuery(status: .cleared),
            TransactionFeedQuery(text: "coffee"),
            TransactionFeedQuery(conditions: [.transfer(true)])
        ]
        for query in queries {
            #expect(!Self.state(Self.page(Self.sample, query: query)).showsRunningBalances)
        }
        #expect(!Self.state(Self.page(Self.sample, withMetadata: false)).showsRunningBalances)
    }

    @Test func gateIsOffOutsideAccountScope() {
        let page = Self.page(Self.sample)
        let state = Self.state(page, scope: .spending)
        #expect(!state.showsRunningBalances)
        #expect(state.runningBalanceSetting == nil)
        #expect(Self.rows(state).allSatisfy { $0.runningBalanceText == nil })
    }

    @Test func noPageHidesBalances() {
        #expect(!Self.state(nil).showsRunningBalances)
    }

    @Test func privacyModeReplacesBalanceText() {
        let normal = Self.rows(Self.state(Self.page(Self.sample, balance: 500)))
        let hidden = Self.rows(Self.state(Self.page(Self.sample, balance: 500), privacy: true))
        let expected = PrivacyDisplay.money(
            500, seed: "running-balance-a", currency: .usd, maximumDollars: 15_000)
        #expect(hidden[0].runningBalanceText == expected)
        #expect(hidden[0].runningBalanceText != normal[0].runningBalanceText)
    }

    @Test func accountPageCarriesSettingAndBalanceFromOneRead() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let url = try fixtures.makeSQLiteFixture(extraSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('show-balances-checking', 'true');
            INSERT INTO preferences VALUES ('show-balances-savings', 'yes');
            INSERT INTO transactions (id, acct, date, amount, tombstone) VALUES ('t2', 'checking', 29990101, 700, 0);
            INSERT INTO transactions (id, acct, date, amount, tombstone) VALUES ('t3', 'checking', 20260704, 9999, 1);
            INSERT INTO transactions (id, acct, date, amount, tombstone) VALUES ('t4', 'savings', 20260704, 5, 0);
            """)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")
        let checking = try await database.fetchAccountTransactionQueryPage(
            accountID: "checking", query: TransactionFeedQuery())
        #expect(checking.runningBalanceSetting == true)
        #expect(checking.balance == -12_345 + 700)
        #expect(checking.page.transactions.map(\.id) == ["t2", "txn"])
        let savings = try await database.fetchAccountTransactionQueryPage(
            accountID: "savings", query: TransactionFeedQuery())
        #expect(savings.runningBalanceSetting == false)
        #expect(savings.balance == 5)
    }

    @Test func budgetWithoutPreferencesTableHasNoSetting() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let database = try BudgetDatabase(databaseURL: try fixtures.makeSQLiteFixture(), localNodeID: "node1")
        let page = try await database.fetchAccountTransactionQueryPage(
            accountID: "checking", query: TransactionFeedQuery())
        #expect(page.runningBalanceSetting == nil)
        #expect(page.balance == -12_345)
    }
}
