import Foundation
@testable import Actualist

actor BudgetViewportTestRepository: BudgetRepositoryProtocol {
    var currentModeIdentity: BudgetModeIdentity?
    var responses: [String: LoadedBudgetMonth] = [:]
    var readErrors: [String: Error] = [:]
    var blockedMonths: Set<String> = []
    var pendingReads: [String: [CheckedContinuation<Void, Never>]] = [:]
    var blockedSignals: [String: [CheckedContinuation<Void, Never>]] = [:]
    var assignmentResult: LoadedBudgetMonth?
    var currentReadError: Error?
    var assignmentBlocked = false
    var pendingAssignments: [CheckedContinuation<Void, Never>] = []
    private var assignmentSignals: [CheckedContinuation<Void, Never>] = []

    func setModeIdentity(_ identity: BudgetModeIdentity?) { currentModeIdentity = identity }
    func budgetModeIdentity(budgetID: String) -> BudgetModeIdentity? { currentModeIdentity }

    func set(_ response: LoadedBudgetMonth) { responses[response.month.month] = response }
    func setError(_ error: Error?, for month: String) {
        if let error { readErrors[month] = error } else { readErrors.removeValue(forKey: month) }
    }
    func setCurrentReadError(_ error: Error?) { currentReadError = error }
    func block(_ month: String) { blockedMonths.insert(month) }

    func waitUntilReadBlocked(_ month: String) async {
        if !pendingReads[month, default: []].isEmpty { return }
        await withCheckedContinuation { continuation in blockedSignals[month, default: []].append(continuation) }
    }

    func release(_ month: String) {
        blockedMonths.remove(month)
        let waiters = pendingReads.removeValue(forKey: month) ?? []
        waiters.forEach { $0.resume() }
    }

    func blockAssignment() { assignmentBlocked = true }
    func waitUntilAssignmentBlocked() async {
        if !pendingAssignments.isEmpty { return }
        await withCheckedContinuation { continuation in assignmentSignals.append(continuation) }
    }
    func releaseAssignment() {
        assignmentBlocked = false
        pendingAssignments.forEach { $0.resume() }
        pendingAssignments.removeAll()
    }

    func currentBudgetMonth(budgetID: String, preferredMonth: String) async throws -> LoadedBudgetMonth {
        if let currentReadError { throw currentReadError }
        return try await budgetMonth(budgetID: budgetID, selectedMonth: preferredMonth)
    }

    func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth {
        if blockedMonths.contains(selectedMonth) {
            blockedSignals.removeValue(forKey: selectedMonth)?.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                pendingReads[selectedMonth, default: []].append(continuation)
            }
        }
        if let error = readErrors[selectedMonth] { throw error }
        guard let response = responses[selectedMonth] else { throw ViewportTestError.missingMonth(selectedMonth) }
        return response
    }

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil, categoryID: String, budgeted: Int, budgetID: String, month: String, didAssign: @escaping () async -> Void) async throws -> LoadedBudgetMonth {
        if assignmentBlocked {
            assignmentSignals.forEach { $0.resume() }
            assignmentSignals.removeAll()
            await withCheckedContinuation { continuation in pendingAssignments.append(continuation) }
        }
        await didAssign()
        let result = assignmentResult ?? BudgetViewportFixtures.loaded(month, categoryID: categoryID, budgeted: budgeted)
        responses[month] = result
        return result
    }

    func budgets() async throws -> [ActualBudget] { [] }
    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil, categoryID: String, carryover: Bool, budgetID: String, startMonth: String, didSetCarryover: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw ViewportTestError.unsupported }
    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil, carryover: Bool, budgetID: String, startMonth: String) async throws -> LoadedBudgetMonth { throw ViewportTestError.unsupported }
    func setCategoryHiddenAndRefresh(categoryID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw ViewportTestError.unsupported }
    func setCategoryGroupHiddenAndRefresh(groupID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw ViewportTestError.unsupported }
    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity? = nil, command: BudgetTemplateCommand, budgetID: String, month: String, didApply: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw ViewportTestError.unsupported }
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil, command: BudgetMoveMoneyCommand, budgetID: String, month: String, didMove: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw ViewportTestError.unsupported }
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil, commands: [BudgetMoveMoneyCommand], budgetID: String, month: String, didMove: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw ViewportTestError.unsupported }
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview { throw ViewportTestError.unsupported }
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws { throw ViewportTestError.unsupported }
}

enum ViewportTestError: Error { case missingMonth(String); case noAssignmentResult; case unsupported }

enum BudgetViewportFixtures {
    static func loaded(_ month: String, categoryID: String = "groceries", hidden: Bool? = false, groupHidden: Bool? = false, budgeted: Int = 100) -> LoadedBudgetMonth {
        let category = BudgetMonthCategory(id: categoryID, name: categoryID.capitalized, isIncome: false, hidden: hidden, groupID: "group", budgeted: budgeted, spent: 0, balance: budgeted, carryover: true)
        let group = BudgetMonthCategoryGroup(id: "group", name: "Bills", isIncome: false, hidden: groupHidden, budgeted: budgeted, spent: 0, balance: budgeted, categories: [category])
        let budget = BudgetMonth(month: month, incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0, totalBudgeted: budgeted, toBudget: 0, fromLastMonth: 0, totalIncome: 0, totalSpent: 0, totalBalance: budgeted, categoryGroups: [group])
        return LoadedBudgetMonth(availableMonths: [month], selectedMonth: month, month: budget, alerts: [])
    }
}
