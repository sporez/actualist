import Foundation
import Testing
@testable import Actualist

struct RunningBalancePreferenceTests {
    private typealias Pref = RunningBalancePreference

    private func ids(_ columns: [Pref.Column]) -> [String] { columns.map(\.id) }
    private func hidden(_ columns: [Pref.Column], _ id: String) -> Bool? {
        columns.first { $0.id == id }?.hidden
    }

    @Test func noLayoutUsesShowBalances() {
        #expect(Pref.isShown(.init(showBalances: "true")))
        #expect(!Pref.isShown(.init(showBalances: "false")))
        #expect(!Pref.isShown(.init(showBalances: "yes")))
        #expect(!Pref.isShown(.init()))
    }

    @Test func savedLayoutDecidesAndIgnoresShowBalances() {
        let visible = #"[{"id":"date","hidden":false},{"id":"balance","hidden":false}]"#
        let hiddenBalance = #"[{"id":"balance","hidden":true}]"#
        #expect(Pref.isShown(.init(viewColumns: visible, showBalances: "false")))
        #expect(!Pref.isShown(.init(viewColumns: hiddenBalance, showBalances: "true")))
        #expect(Pref.isShown(.init(globalColumns: visible)))
        // The account's own layout wins over the budget-wide one.
        #expect(!Pref.isShown(.init(viewColumns: hiddenBalance, globalColumns: visible)))
    }

    @Test func emptyViewLayoutFallsBackLikeJavaScriptOr() {
        let visible = #"[{"id":"balance","hidden":false}]"#
        #expect(Pref.isShown(.init(viewColumns: "", globalColumns: visible)))
        #expect(Pref.isShown(.init(viewColumns: "", globalColumns: "", showBalances: "true")))
    }

    @Test func layoutWithoutBalanceOrMalformedHidesIt() {
        // A saved layout that omits balance gets it at its default: hidden.
        #expect(!Pref.isShown(.init(viewColumns: #"[{"id":"date","hidden":false}]"#, showBalances: "true")))
        // A malformed value still counts as a saved layout; it parses to defaults.
        #expect(!Pref.isShown(.init(viewColumns: "not json", showBalances: "true")))
    }

    @Test func parseDropsInvalidEntriesAndKeepsFirstDuplicate() {
        let columns = Pref.parseColumns("""
            [{"id":"payee","hidden":true},{"id":"payee","hidden":false},{"id":"bogus"},
             "balance",{"hidden":true},{"id":"balance","hidden":"true"},{"id":"date","hidden":true}]
            """)
        #expect(hidden(columns, "payee") == true)
        // Only a boolean true hides; "true" as a string does not.
        #expect(hidden(columns, "balance") == false)
        // Date can never be hidden.
        #expect(hidden(columns, "date") == false)
        #expect(Set(ids(columns)) == Set([
            "date", "account", "payee", "notes", "group", "category", "payment", "deposit", "balance", "cleared",
        ]))
    }

    @Test func parseRestoresBothAmountColumnsAndInsertsMissingAtDefaultPosition() {
        let columns = Pref.parseColumns(#"[{"id":"payment","hidden":true},{"id":"deposit","hidden":true},{"id":"date","hidden":false}]"#)
        #expect(hidden(columns, "payment") == false)
        #expect(hidden(columns, "deposit") == false)
        // Missing columns go before the first saved column whose default index is later.
        #expect(ids(columns) == [
            "account", "payee", "notes", "group", "category", "payment", "deposit", "date", "balance", "cleared",
        ])
        #expect(hidden(columns, "group") == true)
        #expect(hidden(columns, "balance") == true)
    }

    @Test func serializeMatchesJSONStringify() {
        #expect(Pref.serialize([.init(id: "date", hidden: false), .init(id: "balance", hidden: true)])
            == #"[{"id":"date","hidden":false},{"id":"balance","hidden":true}]"#)
    }

    @Test func writesWithoutLayoutTouchOnlyShowBalances() {
        let writes = Pref.writes(enabled: true, accountID: "a1", current: .init())
        #expect(writes.map(\.key.id) == ["show-balances-a1"])
        #expect(writes.map(\.value) == ["true"])
    }

    @Test func writesFlipTheAccountLayoutAndKeepItsOrder() {
        let layout = #"[{"id":"payee","hidden":false},{"id":"date","hidden":false},{"id":"balance","hidden":false}]"#
        let writes = Pref.writes(enabled: false, accountID: "a1", current: .init(viewColumns: layout))
        #expect(writes.map(\.key.id) == ["show-balances-a1", "transaction-table-columns-a1"])
        let columns = Pref.parseColumns(writes[1].value)
        #expect(ids(columns) == [
            "account", "payee", "date", "notes", "group", "category", "payment", "deposit", "balance", "cleared",
        ])
        #expect(hidden(columns, "balance") == true)
        #expect(!Pref.isShown(.init(viewColumns: writes[1].value)))
    }

    @Test func writesCopyABudgetWideLayoutIntoTheAccount() {
        let global = #"[{"id":"date","hidden":false},{"id":"notes","hidden":true}]"#
        let writes = Pref.writes(enabled: true, accountID: "a1", current: .init(globalColumns: global))
        #expect(writes.map(\.key.id) == ["show-balances-a1", "transaction-table-columns-a1"])
        let columns = Pref.parseColumns(writes[1].value)
        #expect(hidden(columns, "notes") == true)
        #expect(hidden(columns, "balance") == false)
    }
}
