import Foundation
import Testing
@testable import Actualist

struct WidgetFinancialSnapshotTests {
    @Test(arguments: [BudgetCurrency.usd, .jpy])
    func preservesBudgetUnitsAndExistingReportTotals(currency: BudgetCurrency) throws {
        let source = makeSource(currency: currency)
        let snapshot = makeSnapshot(source)
        let overview = try #require(snapshot.overview)
        #expect(overview.income.minorUnits == 400000)
        #expect(overview.spent.minorUnits == 12500)
        #expect(overview.toBudget.minorUnits == 15000)
        #expect(overview.available.minorUnits == -2500)
        #expect(overview.income.formatted == currency.formatted(400000))
        #expect(snapshot.accounts?.first?.balance?.formatted == currency.formatted(123456))
        #expect(snapshot.netWorth?.balance.minorUnits == source.netWorth?.balance)
        #expect(snapshot.netWorth?.change.minorUnits == source.netWorth?.change)
        #expect(snapshot.recentTransactions?.map(\.id) == ["transaction"])
        #expect(snapshot.recentTransactions?.first?.payee == "Private Merchant")
        #expect(snapshot.attention?.uncategorizedCount == 7)
        #expect(snapshot.attention?.overspentCategoryIDs == ["category"])
    }

    @Test func missingSectionsAndBalancesNeverBecomeZeroOrAllCaughtUp() throws {
        let snapshot = makeSnapshot(makeSource(unavailable: true))
        #expect(snapshot.overview != nil)
        #expect(snapshot.accounts == nil)
        #expect(snapshot.attention == nil)
        #expect(snapshot.netWorth == nil)
        #expect(snapshot.recentTransactions == nil)
        let complete = makeSnapshot(makeSource())
        #expect(complete.accounts?.last?.balance == nil)
    }

    @Test func privacyRedactsEveryNewPayloadBeforePersistence() throws {
        let snapshot = WidgetFinancialSnapshotBuilder.make(
            source: makeSource(), budgetID: "fixture-budget", budgetName: "Private Household",
            privacyEnabled: true, now: .now
        )
        let json = try String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self)
        for secret in ["Private Household", "Private Account", "Private Merchant", "Private Category", "Private Memo", "123456"] {
            #expect(!json.contains(secret))
        }
        #expect(snapshot.netWorth?.points.last?.amount == snapshot.netWorth?.balance)
        #expect(snapshot.overview?.available.minorUnits == snapshot.categories.reduce(0) { $0 + $1.availableMinorUnits })
        #expect(snapshot.recentTransactions?.first?.amount?.minorUnits != -12500)
    }

    @Test func accountSelectionPreservesOrderDeduplicatesAndRejectsStaleData() {
        let snapshot = makeSnapshot(makeSource())
        let rows = WidgetFinancialProjection.accounts(selectedIDs: ["closed", "account", "account", "missing"], snapshot: snapshot, limit: 16)
        #expect(rows.map(\.id) == ["closed", "account"])
        #expect(WidgetFinancialProjection.accounts(selectedIDs: ["closed", "account"], snapshot: snapshot, limit: 1).map(\.id) == ["closed"])
        var old = snapshot
        old.month = "2001-01"
        #expect(WidgetFinancialProjection.currentSnapshot(old) == nil)
        #expect(WidgetFinancialProjection.accounts(selectedIDs: ["account"], snapshot: old, limit: 16).isEmpty)
    }

    @Test func allPayloadChangesInvalidateDisplayEqualityAndRoundTrip() throws {
        let snapshot = makeSnapshot(makeSource())
        var changed = snapshot
        changed.updatedAt = .distantPast
        #expect(snapshot.hasSameDisplayContent(as: changed))
        changed.attention = WidgetAttentionSnapshot(uncategorizedCount: 8, overspentCategoryIDs: [])
        #expect(!snapshot.hasSameDisplayContent(as: changed))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directoryURL: directory)
        try store.save(snapshot)
        #expect(store.load() == snapshot)
        changed.schemaVersion = 1
        try store.save(changed)
        #expect(store.load() == nil)
    }

    @Test func balanceFamiliesCapSelectionsWithoutMutatingTheConfiguration() {
        #expect(WidgetCategoryBalanceCapacity.maximum(for: .small) == 1)
        #expect(WidgetCategoryBalanceCapacity.maximum(for: .medium) == 3)
        #expect(WidgetCategoryBalanceCapacity.maximum(for: .large) == 8)
        #expect(WidgetCategoryBalanceCapacity.maximum(for: .extraLarge) == 16)
    }

    @Test func accountLinksRoundTripAndRejectExtraPayload() throws {
        #expect(WidgetDeepLink.parse(WidgetDeepLink.url(.account(id: "account with spaces"))) == .account(id: "account with spaces"))
        for value in ["com.sporez.actualist://account", "com.sporez.actualist://account/a/b", "com.sporez.actualist://account/a?token=invalid"] {
            #expect(WidgetDeepLink.parse(try #require(URL(string: value))) == nil)
        }
    }

    @MainActor
    @Test func accountLinkWaitsForSettingsDismissalAndRetainsTheRegister() throws {
        let suite = "WidgetAccountRouteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        state.routeCoordinator.presentSettings()
        WidgetDeepLinkRouter.handle(WidgetDeepLink.url(.account(id: "fixture-account")), appState: state)
        #expect(state.routeCoordinator.pendingRoute == nil)
        state.routeCoordinator.settingsDidDismiss()
        #expect(state.selectedTab == .accounts)
        #expect(state.routeCoordinator.pendingRoute == .account(id: "fixture-account"))
    }

    private func makeSnapshot(_ source: WidgetBudgetSource) -> WidgetSnapshot {
        WidgetFinancialSnapshotBuilder.make(source: source, budgetID: "fixture-budget", budgetName: "Private Household", privacyEnabled: false, now: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func makeSource(currency: BudgetCurrency = .usd, unavailable: Bool = false) -> WidgetBudgetSource {
        let category = BudgetMonthCategory(id: "category", name: "Private Category", isIncome: false, hidden: true, groupID: "group", budgeted: 10000, spent: -12500, balance: -2500, carryover: false)
        let group = BudgetMonthCategoryGroup(id: "group", name: "Private Group", isIncome: false, hidden: false, budgeted: 10000, spent: -12500, balance: -2500, categories: [category])
        let month = BudgetMonth(month: WidgetMonthID.current(), incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0, totalBudgeted: 10000, toBudget: 15000, fromLastMonth: 0, totalIncome: 400000, totalSpent: -12500, totalBalance: -2500, categoryGroups: [group])
        let transaction = ActualTransaction(id: "transaction", account: "account", date: "2026-09-01", amount: -12500, payee: "payee", payeeName: nil, importedPayee: nil, category: "category", notes: "Private Memo", cleared: .bool(true))
        return WidgetBudgetSource(
            month: month, currency: currency,
            accounts: unavailable ? nil : [
                AccountDisplay(account: ActualAccount(id: "account", name: "Private Account", offbudget: false, closed: false), balance: 123456),
                AccountDisplay(account: ActualAccount(id: "closed", name: "Old Account", offbudget: true, closed: true), balance: nil)
            ],
            attention: unavailable ? nil : WidgetAttentionSnapshot(uncategorizedCount: 7, overspentCategoryIDs: ["category"]),
            recentTransactions: unavailable ? nil : [transaction],
            transactionLookup: TransactionRowLookup(payeeNames: ["payee": "Private Merchant"]),
            netWorth: unavailable ? nil : NetWorthReport(points: [ReportValuePoint(dayID: "2026-04-01", value: 100000), ReportValuePoint(dayID: "2026-09-01", value: 125000)], balance: 125000, change: 25000)
        )
    }
}
