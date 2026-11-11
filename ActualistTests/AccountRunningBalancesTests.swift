import Testing
@testable import Actualist

struct AccountRunningBalancesTests {
    static func row(
        _ id: String?, _ amount: Int?, date: String = "2026-08-20", subtransactions: [ActualTransaction] = []
    ) -> ActualTransaction {
        ActualTransaction(
            id: id, account: "checking", date: date, amount: amount, payee: nil, payeeName: nil,
            importedPayee: nil, category: nil, notes: nil, cleared: .bool(false),
            subtransactions: subtransactions, isParent: !subtransactions.isEmpty
        )
    }

    @Test func emptyAccountHasNoBalances() {
        let balances = AccountRunningBalances(rows: [], startingBalance: 500)
        #expect(balances.balance(forRowID: "a") == nil)
    }

    @Test func firstRowCarriesStartingBalanceAndEachNextSubtractsTheOneAbove() {
        let rows = [Self.row("a", -300), Self.row("b", 1_000), Self.row("c", -200)]
        let balances = AccountRunningBalances(rows: rows, startingBalance: 500)
        #expect(balances.balance(forRowID: "a") == 500)
        #expect(balances.balance(forRowID: "b") == 800)
        #expect(balances.balance(forRowID: "c") == -200)
    }

    @Test func singleRowShowsStartingBalance() {
        let balances = AccountRunningBalances(rows: [Self.row("a", 42)], startingBalance: 42)
        #expect(balances.balance(forRowID: "a") == 42)
    }

    @Test func rowWithoutIDIsKeyedByRowID() {
        let anonymous = Self.row(nil, -100)
        let balances = AccountRunningBalances(rows: [Self.row("a", -50), anonymous], startingBalance: 10)
        #expect(balances.balance(forRowID: anonymous.rowID) == 60)
    }

    @Test func nilAmountCountsAsZero() {
        let rows = [Self.row("a", nil), Self.row("b", -100), Self.row("c", 5)]
        let balances = AccountRunningBalances(rows: rows, startingBalance: 70)
        #expect(balances.balance(forRowID: "b") == 70)
        #expect(balances.balance(forRowID: "c") == 170)
    }

    @Test func splitParentUsesItsOwnAmountNotItsChildren() {
        let children = [Self.row("c1", -100), Self.row("c2", -50)]
        let parent = Self.row("p", -400, subtransactions: children)
        let balances = AccountRunningBalances(rows: [parent, Self.row("n", -10)], startingBalance: 1_000)
        #expect(balances.balance(forRowID: "p") == 1_000)
        #expect(balances.balance(forRowID: "n") == 1_400)
        #expect(balances.balance(forRowID: "c1") == nil)
    }

    @Test func futureDatedRowsAreIncluded() {
        let rows = [Self.row("future", -100, date: "2999-01-01"), Self.row("now", -100)]
        let balances = AccountRunningBalances(rows: rows, startingBalance: 300)
        #expect(balances.balance(forRowID: "future") == 300)
        #expect(balances.balance(forRowID: "now") == 400)
    }

    @Test func olderPagesContinueTheSequence() {
        let first = [Self.row("a", -100), Self.row("b", -200)]
        let older = [Self.row("c", 50)]
        let whole = AccountRunningBalances(rows: first + older, startingBalance: 1_000)
        #expect(whole.balance(forRowID: "c") == 1_300)
        #expect(AccountRunningBalances(rows: first, startingBalance: 1_000).balance(forRowID: "b") == 1_100)
    }
}
