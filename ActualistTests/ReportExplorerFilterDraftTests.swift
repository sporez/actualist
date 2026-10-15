import Testing
@testable import Actualist

@Suite("Report Explorer Filter Draft")
struct ReportExplorerFilterDraftTests {
    private static let accounts = [
        ReportExplorerAccountFilterOption(id: "checking", name: "Checking", isOffBudget: false, isClosed: false),
        ReportExplorerAccountFilterOption(id: "savings", name: "Savings", isOffBudget: false, isClosed: false),
        ReportExplorerAccountFilterOption(id: "ira", name: "IRA", isOffBudget: true, isClosed: false),
        ReportExplorerAccountFilterOption(id: "401k", name: "401k", isOffBudget: true, isClosed: false),
        ReportExplorerAccountFilterOption(id: "old-brokerage", name: "Old", isOffBudget: true, isClosed: true),
    ]

    private static let categories = [
        ReportExplorerCategoryFilterOption(
            id: "rent", name: "Rent", groupID: "needs", groupName: "Needs", isIncome: false, isHidden: false
        ),
        ReportExplorerCategoryFilterOption(
            id: "food", name: "Food", groupID: "needs", groupName: "Needs", isIncome: false, isHidden: false
        ),
        ReportExplorerCategoryFilterOption(
            id: "legacy", name: "Legacy", groupID: "needs", groupName: "Needs", isIncome: false, isHidden: true
        ),
    ]

    private static let spendingDefaults = ReportExplorerFilters.defaults(for: .spending)

    private func makeDraft(
        _ filters: ReportExplorerFilters = spendingDefaults,
        defaults: ReportExplorerFilters = spendingDefaults
    ) -> ReportExplorerFilterDraft {
        ReportExplorerFilterDraft(
            filters: filters,
            defaults: defaults,
            accounts: Self.accounts,
            categories: Self.categories
        )
    }

    @Test func distinguishesAllSomeAndExplicitlyEmptySelections() {
        var draft = makeDraft()

        draft.setAccount("checking", included: false)
        #expect(draft.filters.accounts == .only(["savings", "ira", "401k", "old-brokerage"]))
        draft.setAccount("checking", included: true)
        #expect(draft.filters.accounts == .all)

        draft.clearAccounts()
        draft.clearCategories()
        #expect(draft.filters.accounts == .only([]))
        #expect(draft.filters.categories == .only([]))
        #expect(!draft.filters.includesUncategorized)
    }

    @Test func offBudgetRowsReadOffWhileTheirSwitchIsOff() {
        let draft = makeDraft()

        #expect(!draft.filters.includesOffBudget)
        #expect(draft.filters.accounts == .all)
        #expect(draft.isAccountIncluded("checking"))
        #expect(!draft.isAccountIncluded("ira"))
        #expect(!draft.isAccountIncluded("old-brokerage"))
    }

    @Test func turningOnOneOffBudgetRowIncludesOnlyThatAccount() {
        var draft = makeDraft()

        draft.setAccount("ira", included: true)

        #expect(draft.filters.includesOffBudget)
        #expect(draft.filters.accounts == .only(["checking", "savings", "ira"]))
        #expect(draft.isAccountIncluded("ira"))
        #expect(!draft.isAccountIncluded("401k"))
        #expect(!draft.isAccountIncluded("old-brokerage"))
        #expect(draft.isAccountIncluded("checking"))
    }

    @Test func offBudgetSwitchTurnsEveryOffBudgetRowOnAndOff() {
        var draft = makeDraft(ReportExplorerFilters(
            accounts: .only(["checking"]),
            categories: .all,
            includesOffBudget: false,
            includesHiddenCategories: true,
            includesUncategorized: true
        ))

        draft.setIncludesOffBudget(true)
        #expect(draft.filters.accounts == .only(["checking", "ira", "401k", "old-brokerage"]))
        #expect(draft.isAccountIncluded("ira"))
        #expect(!draft.isAccountIncluded("savings"))

        draft.setIncludesOffBudget(false)
        #expect(!draft.isAccountIncluded("ira"))
        #expect(draft.isAccountIncluded("checking"))
    }

    @Test func closingTheDefaultOffBudgetSwitchKeepsTheDefaultSelection() {
        var draft = makeDraft()

        draft.setIncludesOffBudget(true)
        #expect(draft.filters.accounts == .all)
        draft.setIncludesOffBudget(false)

        #expect(draft.filters == Self.spendingDefaults)
    }

    @Test func allAndNoneMatchEveryAccountRow() {
        var draft = makeDraft()

        draft.selectAllAccounts()
        #expect(Self.accounts.allSatisfy { draft.isAccountIncluded($0.id) })

        draft.clearAccounts()
        #expect(Self.accounts.allSatisfy { !draft.isAccountIncluded($0.id) })
        #expect(!draft.filters.includesOffBudget)
    }

    @Test func hiddenCategoryRowsFollowTheirSwitch() {
        var draft = makeDraft()
        #expect(draft.isCategoryIncluded("legacy"))

        draft.setIncludesHiddenCategories(false)
        #expect(!draft.isCategoryIncluded("legacy"))
        #expect(draft.isCategoryIncluded("rent"))

        draft.setCategory("legacy", included: true)
        #expect(draft.filters.includesHiddenCategories)
        #expect(draft.isCategoryIncluded("legacy"))
        #expect(draft.filters.categories == .all)
    }

    @Test func allAndNoneMatchEveryCategoryRow() {
        var draft = makeDraft()

        draft.clearCategories()
        #expect(Self.categories.allSatisfy { !draft.isCategoryIncluded($0.id) })
        #expect(!draft.filters.includesHiddenCategories)
        #expect(!draft.filters.includesUncategorized)

        draft.selectAllCategories()
        #expect(Self.categories.allSatisfy { draft.isCategoryIncluded($0.id) })
        #expect(draft.filters.includesUncategorized)
    }

    @Test func transferSwitchIncludesAllTransfersOrNone() {
        var calendarDefaults = Self.spendingDefaults
        calendarDefaults.transfers = .transfers
        var draft = makeDraft(calendarDefaults, defaults: calendarDefaults)
        #expect(draft.includesTransfers)

        draft.setIncludesTransfers(false)
        #expect(draft.filters.transfers == .nonTransfers)
        draft.setIncludesTransfers(true)
        #expect(draft.filters.transfers == .all)

        draft.reset()
        #expect(draft.filters.transfers == .transfers)
    }

    @Test func resetRestoresDefaultFilters() {
        var draft = makeDraft()
        draft.selectAllAccounts()
        draft.clearCategories()

        draft.reset()

        #expect(draft.filters == Self.spendingDefaults)
    }

    @Test func netWorthStartsWithEveryAccountIncludedAndResetsBackToIt() {
        let netWorthDefaults = ReportExplorerFilters.defaults(for: .netWorth)
        var draft = makeDraft(netWorthDefaults, defaults: netWorthDefaults)
        #expect(Self.accounts.allSatisfy { draft.isAccountIncluded($0.id) })

        draft.setIncludesOffBudget(false)
        #expect(!draft.isAccountIncluded("ira"))

        draft.reset()
        #expect(draft.filters == netWorthDefaults)
        #expect(draft.isAccountIncluded("ira"))
    }
}
