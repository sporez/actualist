import Foundation
import Observation

/// Window-local state for the wide budget presentation.
///
/// The viewport shares its window's assignment workflow with compact Budget. Month values
/// remain `LoadedBudgetMonth` snapshots from that repository; the optional
/// privacy projection is applied only when the view asks for display data.
@MainActor
@Observable
final class BudgetViewportModel {
    struct SelectedCell: Hashable, Sendable {
        let categoryID: String
        let month: String
    }

    let repository: any BudgetRepositoryProtocol
    let assignmentWorkflow: BudgetAssignmentWorkflow

    private(set) var budgetID: String?
    private(set) var anchorMonth: String?
    private(set) var monthSnapshots: [String: LoadedBudgetMonth] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var monthErrors: [String: String] = [:]
    private var generation = 0
    private var budgetGeneration = 0
    private var hardwareInputText = ""
    private var expansionInitializedBudgetID: String?

    var resolvedMonthCount: Int = 1
    var showHidden = false
    var expandedGroupIDs: Set<String> = []
    var selectedCell: SelectedCell? {
        assignmentWorkflow.context.map { SelectedCell(categoryID: $0.categoryID, month: $0.month) }
    }
    private(set) var inspectedCell: SelectedCell?
    var selectedCategoryMonth: String? { inspectedCell?.month }

    func assignmentAmountDisplay(randomized: Bool) -> BudgetAssignedAmountDisplay? {
        guard let selectedCell, let category = category(at: selectedCell),
              let currency = currencyForSelectedCell else { return nil }
        let displayCategory = randomized ? BudgetMonthPrivacyProjection.project(category: category,
            month: selectedCell.month, currency: currency, table: isTrackingBudget ? .tracking : .envelope) : category
        return assignmentWorkflow.amountDisplay(for: displayCategory, currency: currency, randomized: randomized)
    }

    var assignmentHasTemplate: Bool {
        guard let selectedCell else { return false }
        return BudgetTemplateActionAvailability.hasCategoryAction(
            for: selectedCell.categoryID,
            in: monthSnapshots[selectedCell.month]?.month.categoryGroups ?? []
        )
    }

    var selectedCategoryDetails: CategoryMonthDetails? {
        guard let inspectedCell,
              let category = category(at: inspectedCell) else {
            return nil
        }
        return CategoryMonthDetails(
            category: category,
            month: inspectedCell.month,
            modeIdentity: monthSnapshots[inspectedCell.month]?.modeIdentity
        )
    }

    init(repository: any BudgetRepositoryProtocol, assignmentWorkflow: BudgetAssignmentWorkflow? = nil) {
        self.repository = repository
        self.assignmentWorkflow = assignmentWorkflow ?? BudgetAssignmentWorkflow()
    }

    var visibleMonths: [String] {
        guard let anchorMonth else { return [] }
        return (0..<max(1, min(resolvedMonthCount, 5))).map {
            Self.monthID(anchorMonth, offsetBy: $0)
        }
    }

    var visibleSnapshots: [LoadedBudgetMonth] {
        visibleMonths.compactMap { monthSnapshots[$0] }
    }

    var isTrackingBudget: Bool {
        visibleSnapshots.first?.isTrackingBudget == true
    }

    var modeIdentity: BudgetModeIdentity? {
        visibleSnapshots.first?.modeIdentity
    }

    func snapshot(for month: String) -> LoadedBudgetMonth? { monthSnapshots[month] }

    func setResolvedMonthCount(_ count: Int) {
        resolvedMonthCount = max(1, min(count, 5))
        trimCache()
    }

    /// Reconciles the workspace task identity without creating another budget
    /// model. Existing viewport state wins when it already belongs to this
    /// budget; compact state seeds only a new budget/window.
    func activate(
        budgetID: String,
        compactModel: BudgetViewModel,
        monthCount: Int
    ) async {
        let sameBudget = self.budgetID == budgetID && anchorMonth != nil
        setResolvedMonthCount(monthCount)
        if sameBudget {
            _ = await refreshVisibleMonths()
        } else {
            await adoptCompactState(compactModel, budgetID: budgetID)
        }
    }

    func load(budgetID: String, anchorMonth: String? = nil, preservingAssignment: Bool = false) async {
        if !preservingAssignment, self.anchorMonth != anchorMonth {
            assignmentWorkflow.invalidate()
        }
        assignmentWorkflow.reconcile(budgetID: budgetID)
        generation += 1
        let requestGeneration = generation
        let previousBudgetID = self.budgetID
        self.budgetID = budgetID
        self.anchorMonth = anchorMonth
        if previousBudgetID != budgetID {
            budgetGeneration += 1
            monthSnapshots = [:]
            expandedGroupIDs = []
            inspectedCell = nil
            expansionInitializedBudgetID = nil
            hardwareInputText = ""
        }
        errorMessage = nil
        monthErrors = [:]
        isLoading = true

        do {
            let first: LoadedBudgetMonth
            if let anchorMonth {
                first = try await repository.budgetMonth(
                    budgetID: budgetID,
                    selectedMonth: anchorMonth
                )
            } else {
                first = try await repository.currentBudgetMonth(
                    budgetID: budgetID,
                    preferredMonth: YearMonth(date: Date()).rawValue
                )
            }
            try Task.checkCancellation()
            guard requestGeneration == generation, self.budgetID == budgetID else { return }
            self.anchorMonth = first.month.month
            try await loadVisibleMonths(
                generation: requestGeneration,
                seed: first
            )
        } catch where error.isCancellation {
            if requestGeneration == generation { isLoading = false }
            return
        } catch {
            guard requestGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
        if requestGeneration == generation { isLoading = false }
    }

    func moveAnchor(by offset: Int) async {
        guard let anchorMonth, let budgetID else { return }
        await load(budgetID: budgetID, anchorMonth: Self.monthID(anchorMonth, offsetBy: offset))
    }

    func jumpToCurrentMonth() async {
        guard let budgetID else { return }
        await load(budgetID: budgetID, anchorMonth: YearMonth(date: Date()).rawValue)
    }

    func selectCategory(categoryID: String, month: String) {
        let cell = SelectedCell(categoryID: categoryID, month: month)
        inspectedCell = category(at: cell) == nil ? nil : cell
    }

    func toggleGroup(id: String) {
        if expandedGroupIDs.contains(id) { expandedGroupIDs.remove(id) }
        else { expandedGroupIDs.insert(id) }
    }

    func closeInspector() {
        inspectedCell = nil
    }

    func setShowHidden(_ value: Bool) {
        showHidden = value
        normalizeState(using: visibleSnapshots.first?.month)
    }

    func adoptCompactState(_ compactModel: BudgetViewModel, budgetID: String) async {
        let belongsToBudget = compactModel.loadedBudgetID == budgetID
        let month = belongsToBudget
            ? (compactModel.selectedMonth ?? compactModel.budgetMonth?.month)
            : nil
        let expansion = belongsToBudget ? compactModel.expandedGroupIDs : nil
        let anchor = assignmentWorkflow.isPresented && self.budgetID == budgetID ? anchorMonth : month
        await load(budgetID: budgetID, anchorMonth: anchor, preservingAssignment: true)
        if let expansion {
            let validIDs = Set(visibleSnapshots.first?.month.categoryGroups.filter { !$0.isIncome || isTrackingBudget }.map(\.id) ?? [])
            expandedGroupIDs = expansion.intersection(validIDs)
        }
        synchronizeHardwareBuffer()
    }

    func prepareCompactState(_ compactModel: BudgetViewModel) async {
        guard let budgetID, let anchorMonth else { return }
        closeInspector()
        let editingMonth = assignmentWorkflow.context?.month ?? anchorMonth
        await compactModel.selectMonth(editingMonth, budgetID: budgetID, repository: repository)
        compactModel.expandedGroupIDs = expandedGroupIDs
    }

    func beginAssignmentEditing(categoryID: String, month: String) {
        let cell = SelectedCell(categoryID: categoryID, month: month)
        guard !assignmentWorkflow.isSubmitting, visibleMonths.contains(month),
              let category = category(at: cell), (!category.isIncome || monthSnapshots[month]?.isTrackingBudget == true) else { return }
        assignmentWorkflow.begin(
            for: category,
            budgetID: budgetID,
            month: month,
            modeIdentity: monthSnapshots[month]?.modeIdentity
        )
        hardwareInputText = ""
    }

    /// Handles one hardware-keyboard token. Return/Tab submit through the
    /// shared assignment workflow; this method never performs money math.
    @discardableResult
    func handleHardwareInput(_ input: String) async -> Bool {
        guard assignmentWorkflow.isPresented, !assignmentWorkflow.isSubmitting,
              let action = BudgetAssignmentHardwareInput.action(for: input) else { return false }
        switch action {
        case .digit(let digit):
            return replaceHardwareInput(hardwareInputText + String(digit))
        case .decimalPoint:
            guard currencyForSelectedCell?.decimalPlaces != 0,
                  !hardwareInputText.contains(".") else { return false }
            return replaceHardwareInput(hardwareInputText.isEmpty ? "0." : hardwareInputText + ".")
        case .addition, .subtraction:
            assignmentWorkflow.setInputMode(action == .addition ? .addition : .subtraction)
            hardwareInputText = ""
            assignmentWorkflow.replaceInputDigits("")
            return true
        case .commit:
            return await submitAssignment()
        case .cancel:
            cancelAssignmentEditing()
            hardwareInputText = ""
            return true
        case .delete:
            guard !hardwareInputText.isEmpty else { return false }
            return replaceHardwareInput(String(hardwareInputText.dropLast()))
        case .next:
            return await traverseAssignment(backward: false)
        case .previous:
            return await traverseAssignment(backward: true)
        }
    }

    @discardableResult
    func traverseAssignment(backward: Bool) async -> Bool {
        guard let selectedCell else { return false }
        let context = budgetGeneration
        let cells = editableCells()
        guard let index = cells.firstIndex(of: selectedCell), cells.count > 1 else { return false }
        let nextIndex = (index + (backward ? -1 : 1) + cells.count) % cells.count
        if assignmentWorkflow.draft?.inputDigits.isEmpty == false {
            guard await submitAssignment() else { return false }
        } else {
            assignmentWorkflow.cancel()
        }
        guard context == budgetGeneration else { return false }
        beginAssignmentEditing(categoryID: cells[nextIndex].categoryID, month: cells[nextIndex].month)
        return true
    }

    func submitAssignment() async -> Bool {
        guard let budgetID, let selectedCell,
              !assignmentWorkflow.isSubmitting else { return false }
        let context = budgetGeneration
        guard await assignmentWorkflow.submit(
                  selectedMonth: selectedCell.month,
                  budgetID: budgetID,
                  repository: repository
              ) != nil else { return false }
        guard context == budgetGeneration else { return false }
        hardwareInputText = ""
        // Publish all displayed months together, including balances carried
        // forward by the assignment, without changing the navigation anchor.
        _ = await refreshVisibleMonths()
        return true
    }

    func cancelAssignmentEditing() {
        assignmentWorkflow.cancel()
        if !assignmentWorkflow.isPresented {
            hardwareInputText = ""
        }
    }

    func appendKeypadDigit(_ digit: Int) {
        assignmentWorkflow.appendDigit(digit)
        synchronizeHardwareBuffer()
    }

    func deleteKeypadDigit() {
        assignmentWorkflow.deleteDigit()
        synchronizeHardwareBuffer()
    }

    func clearKeypadInput() {
        assignmentWorkflow.clearInputOrCancel()
        synchronizeHardwareBuffer()
    }

    func setAssignmentInputMode(_ mode: BudgetAssignmentInputMode) {
        assignmentWorkflow.setInputMode(mode)
    }

    func showAssignmentDetails() {
        guard let selectedCell else { return }
        selectCategory(categoryID: selectedCell.categoryID, month: selectedCell.month)
        cancelAssignmentEditing()
    }

    private var currencyForSelectedCell: BudgetCurrency? {
        guard let selectedCell else { return nil }
        return monthSnapshots[selectedCell.month]?.currency
    }

    private func replaceHardwareInput(_ text: String) -> Bool {
        if text.isEmpty {
            hardwareInputText = ""
            assignmentWorkflow.replaceInputDigits("")
            return true
        }
        guard assignmentWorkflow.isPresented,
              let currency = currencyForSelectedCell,
              let digits = BudgetAssignmentHardwareInput.minorDigits(
                  for: text,
                  currency: currency
              ) else { return false }
        assignmentWorkflow.replaceInputDigits(digits)
        hardwareInputText = text
        return true
    }

    private func synchronizeHardwareBuffer() {
        guard let digits = assignmentWorkflow.draft?.inputDigits, !digits.isEmpty,
              let currency = currencyForSelectedCell else {
            hardwareInputText = ""
            return
        }
        let padded = String(repeating: "0", count: max(0, currency.decimalPlaces + 1 - digits.count)) + digits
        if currency.decimalPlaces == 0 { hardwareInputText = padded }
        else {
            let split = padded.index(padded.endIndex, offsetBy: -currency.decimalPlaces)
            hardwareInputText = String(padded[..<split]) + "." + padded[split...]
        }
    }

    private func editableCells() -> [SelectedCell] {
        visibleMonths.flatMap { month -> [SelectedCell] in
            guard let snapshot = monthSnapshots[month] else { return [] }
            return snapshot.month.categoryGroups
                .filter { (!$0.isIncome || snapshot.isTrackingBudget) && expandedGroupIDs.contains($0.id) }
                .flatMap { group in
                    BudgetCategoryVisibility.displayedCategories(in: group, showHidden: showHidden)
                        .map { SelectedCell(categoryID: $0.id, month: month) }
                }
        }
    }

    @discardableResult
    func refreshVisibleMonths() async -> Bool {
        guard let budgetID else { return false }
        if anchorMonth == nil {
            await load(budgetID: budgetID)
            return self.budgetID == budgetID && !Task.isCancelled && errorMessage == nil
                && !visibleSnapshots.isEmpty && visibleMonths.allSatisfy { monthErrors[$0] == nil }
        }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            try await loadVisibleMonths(generation: requestGeneration, budgetID: budgetID)
        } catch where error.isCancellation {
            if requestGeneration == generation { isLoading = false }
            return false
        } catch {
            if requestGeneration == generation { errorMessage = error.localizedDescription }
            return false
        }
        guard requestGeneration == generation else { return false }
        return visibleMonths.allSatisfy { monthErrors[$0] == nil }
    }

    private func loadVisibleMonths(
        generation requestGeneration: Int,
        budgetID: String? = nil,
        seed: LoadedBudgetMonth? = nil
    ) async throws {
        let id = budgetID ?? self.budgetID ?? ""
        var staged: [String: LoadedBudgetMonth] = [:]
        var stagedErrors: [String: String] = [:]
        let months = retainedMonths
        var latestIdentity: BudgetModeIdentity?
        for month in months {
            try Task.checkCancellation()
            do {
                let loaded: LoadedBudgetMonth
                if let seed, seed.month.month == month {
                    loaded = seed
                } else {
                    loaded = try await repository.budgetMonth(budgetID: id, selectedMonth: month)
                }
                staged[month] = loaded
                latestIdentity = loaded.modeIdentity
                stagedErrors.removeValue(forKey: month)
            } catch where error.isCancellation {
                throw CancellationError()
            } catch {
                stagedErrors[month] = error.localizedDescription
            }
            guard requestGeneration == generation, self.budgetID == id else { return }
        }
        guard requestGeneration == generation, self.budgetID == id else { return }
        let currentIdentity = try await repository.budgetModeIdentity(budgetID: id) ?? latestIdentity
        guard requestGeneration == generation, self.budgetID == id else { return }
        let staleMonths = Set(monthSnapshots.keys.filter { monthSnapshots[$0]?.modeIdentity != currentIdentity })
            .union(staged.keys.filter { staged[$0]?.modeIdentity != currentIdentity })
        if !staleMonths.isEmpty {
            assignmentWorkflow.invalidate()
            inspectedCell = nil
            expansionInitializedBudgetID = nil
        }
        // A failed month may retain its prior data only in the same conversion.
        monthSnapshots = monthSnapshots.filter { $0.value.modeIdentity == currentIdentity }
        staged = staged.filter { $0.value.modeIdentity == currentIdentity }
        for month in staleMonths where staged[month] == nil {
            stagedErrors[month] = stagedErrors[month] ?? "Budget changed. Refresh this month."
        }
        monthSnapshots.merge(staged) { _, replacement in replacement }
        for month in staged.keys { monthErrors.removeValue(forKey: month) }
        monthErrors.merge(stagedErrors) { _, replacement in replacement }
        normalizeState(using: visibleMonths.compactMap { staged[$0]?.month }.first)
        trimCache()
    }

    private func normalizeState(using month: BudgetMonth?) {
        guard let month else { return }
        let groups = Set(month.categoryGroups.filter { !$0.isIncome || isTrackingBudget }.map(\.id))
        if expansionInitializedBudgetID == budgetID {
            expandedGroupIDs.formIntersection(groups)
        } else {
            expandedGroupIDs = Set(month.categoryGroups.filter { (!$0.isIncome || isTrackingBudget) && $0.hidden != true }.map(\.id))
            expansionInitializedBudgetID = budgetID
        }
        if let selectedCell, category(at: selectedCell) == nil {
            assignmentWorkflow.invalidate()
            hardwareInputText = ""
        }
        if let inspectedCell, category(at: inspectedCell) == nil {
            self.inspectedCell = nil
        }
    }

    private func category(at cell: SelectedCell) -> BudgetMonthCategory? {
        monthSnapshots[cell.month]?.month.categoryGroups.lazy
            .flatMap { BudgetCategoryVisibility.displayedCategories(in: $0, showHidden: self.showHidden) }
            .first { $0.id == cell.categoryID }
    }

    private var retainedMonths: [String] {
        var keep = Set(visibleMonths)
        if let selectedCell { keep.insert(selectedCell.month) }
        if let selectedCategoryMonth { keep.insert(selectedCategoryMonth) }
        return keep.sorted()
    }

    private func trimCache() {
        let keep = Set(retainedMonths)
        monthSnapshots = monthSnapshots.filter { keep.contains($0.key) }
        monthErrors = monthErrors.filter { keep.contains($0.key) }
    }

    static func monthID(_ month: String, offsetBy offset: Int) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1])) else {
            return month
        }
        let shifted = Calendar(identifier: .gregorian).date(byAdding: .month, value: offset, to: date) ?? date
        return YearMonth(date: shifted).rawValue
    }
}
