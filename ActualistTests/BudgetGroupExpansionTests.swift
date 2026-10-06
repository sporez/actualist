import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetGroupExpansionTests {
    @Test func defaultsExpandVisibleGroupsExceptHiddenAndEnvelopeIncome() {
        let groups = Self.groups()

        #expect(BudgetGroupExpansion().expandedIDs(in: groups, isTrackingBudget: false) == ["bills"])
        #expect(BudgetGroupExpansion().expandedIDs(in: groups, isTrackingBudget: true) == ["bills", "income"])
    }

    @Test func recordedChoicesOverrideDefaultsAndForgetDeletedGroups() {
        var expansion = BudgetGroupExpansion(choices: ["deleted": false])
        let liveIDs = Set(Self.groups().map(\.id))

        expansion.record(isExpanded: false, groupID: "bills", liveGroupIDs: liveIDs)
        expansion.record(isExpanded: true, groupID: "archive", liveGroupIDs: liveIDs)

        #expect(expansion.choices == ["bills": false, "archive": true])
        #expect(expansion.expandedIDs(in: Self.groups(), isTrackingBudget: false) == ["archive"])
    }

    @Test func compactCollapseSurvivesANewModelAndAnotherMonth() throws {
        let store = FakeBudgetGroupExpansionStore()
        let model = BudgetViewModel(
            initialMonth: Self.loaded("2026-09"), initialBudgetID: "budget", expansionStore: store
        )
        let bills = try #require(model.visibleGroups.first { $0.id == "bills" })

        model.toggle(bills)

        #expect(store.expansionByBudgetID["budget"]?.choices == ["bills": false])
        let relaunched = BudgetViewModel(
            initialMonth: Self.loaded("2026-10"), initialBudgetID: "budget", expansionStore: store
        )
        #expect(relaunched.expandedGroupIDs.isEmpty)
        let otherBudget = BudgetViewModel(
            initialMonth: Self.loaded("2026-10"), initialBudgetID: "other", expansionStore: store
        )
        #expect(otherBudget.expandedGroupIDs == ["bills"])
    }

    @Test func wideToggleIsSharedWithCompactThroughTheStore() async {
        let store = FakeBudgetGroupExpansionStore()
        let repository = BudgetViewportTestRepository()
        await repository.set(Self.loaded("2026-09"))
        let viewport = BudgetViewportModel(repository: repository, expansionStore: store)
        await viewport.load(budgetID: "budget", anchorMonth: "2026-09")
        #expect(viewport.expandedGroupIDs == ["bills"])

        viewport.toggleGroup(id: "archive")

        #expect(store.expansionByBudgetID["budget"]?.choices == ["archive": true])
        let compact = BudgetViewModel(
            initialMonth: Self.loaded("2026-09"), initialBudgetID: "budget", expansionStore: store
        )
        #expect(compact.expandedGroupIDs == ["bills", "archive"])
        let reopened = BudgetViewportModel(repository: repository, expansionStore: store)
        await reopened.load(budgetID: "budget", anchorMonth: "2026-09")
        #expect(reopened.expandedGroupIDs == ["bills", "archive"])
    }

    @Test func settingsPersistExpansionAndOlderSettingsDecodeWithoutIt() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.GroupExpansion.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        #expect(store.load().categoryGroupExpansionByBudgetID.isEmpty)

        var settings = store.load()
        settings.categoryGroupExpansionByBudgetID["budget"] = BudgetGroupExpansion(choices: ["bills": false])
        store.save(settings)

        #expect(store.load().categoryGroupExpansionByBudgetID["budget"]?.choices == ["bills": false])
    }

    private static func groups() -> [BudgetMonthCategoryGroup] {
        [
            group("bills", hidden: false),
            group("archive", hidden: true),
            group("income", hidden: false, isIncome: true)
        ]
    }

    private static func group(_ id: String, hidden: Bool, isIncome: Bool = false) -> BudgetMonthCategoryGroup {
        let category = BudgetMonthCategory(
            id: "\(id)-category", name: id.capitalized, isIncome: isIncome, hidden: false,
            groupID: id, budgeted: 0, spent: 0, balance: 0, carryover: false
        )
        return BudgetMonthCategoryGroup(
            id: id, name: id.capitalized, isIncome: isIncome, hidden: hidden,
            budgeted: 0, spent: 0, balance: 0, categories: [category]
        )
    }

    private static func loaded(_ month: String) -> LoadedBudgetMonth {
        let budget = BudgetMonth(
            month: month, incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0, totalBudgeted: 0,
            toBudget: 0, fromLastMonth: 0, totalIncome: 0, totalSpent: 0, totalBalance: 0,
            categoryGroups: groups()
        )
        return LoadedBudgetMonth(availableMonths: [month], selectedMonth: month, month: budget, alerts: [])
    }
}

@MainActor
private final class FakeBudgetGroupExpansionStore: BudgetGroupExpansionStore {
    var expansionByBudgetID: [String: BudgetGroupExpansion] = [:]

    func groupExpansion(budgetID: String) -> BudgetGroupExpansion {
        expansionByBudgetID[budgetID] ?? BudgetGroupExpansion()
    }

    func setGroupExpansion(_ expansion: BudgetGroupExpansion, budgetID: String) {
        expansionByBudgetID[budgetID] = expansion
    }
}
