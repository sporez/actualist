import Foundation
import Observation

/// Window-local state for the wide budget presentation.
///
/// A viewport owns one repository and one assignment workflow.  Month values
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
    private(set) var assignmentWorkflow = BudgetAssignmentWorkflow()

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
    private(set) var selectedCell: SelectedCell?
    private(set) var inspectedCell: SelectedCell?
    var selectedCategoryMonth: String? { inspectedCell?.month }

    var assignmentAmountDisplay: BudgetAssignedAmountDisplay? {
        guard let selectedCell, let category = category(at: selectedCell),
              let currency = currencyForSelectedCell else { return nil }
        return assignmentWorkflow.amountDisplay(for: category, currency: currency)
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
        return CategoryMonthDetails(category: category, month: inspectedCell.month)
    }

    init(repository: any BudgetRepositoryProtocol) {
        self.repository = repository
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

    func load(budgetID: String, anchorMonth: String? = nil) async {
        generation += 1
        let requestGeneration = generation
        let previousBudgetID = self.budgetID
        self.budgetID = budgetID
        self.anchorMonth = anchorMonth
        if previousBudgetID != budgetID {
            budgetGeneration += 1
            monthSnapshots = [:]
            expandedGroupIDs = []
            selectedCell = nil
            inspectedCell = nil
            expansionInitializedBudgetID = nil
            // An old budget's in-flight write may finish, but cannot alter a
            // new budget's draft or selection.
            assignmentWorkflow = BudgetAssignmentWorkflow()
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
        } catch is CancellationError {
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
        await load(budgetID: budgetID, anchorMonth: month)
        if let expansion { expandedGroupIDs.formIntersection(expansion) }
        assignmentWorkflow.cancel()
    }

    func prepareCompactState(_ compactModel: BudgetViewModel) async {
        guard let budgetID, let anchorMonth else { return }
        closeInspector()
        assignmentWorkflow.cancel()
        await compactModel.selectMonth(anchorMonth, budgetID: budgetID, repository: repository)
        compactModel.expandedGroupIDs = expandedGroupIDs
    }

    func beginAssignmentEditing(categoryID: String, month: String) {
        let cell = SelectedCell(categoryID: categoryID, month: month)
        guard !assignmentWorkflow.isSubmitting, visibleMonths.contains(month),
              let category = category(at: cell), !category.isIncome else { return }
        selectedCell = cell
        assignmentWorkflow.begin(for: category)
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
        let workflow = assignmentWorkflow
        let cells = editableCells()
        guard let index = cells.firstIndex(of: selectedCell), cells.count > 1 else { return false }
        let nextIndex = (index + (backward ? -1 : 1) + cells.count) % cells.count
        if assignmentWorkflow.draft?.inputDigits.isEmpty == false {
            guard await submitAssignment() else { return false }
        } else {
            assignmentWorkflow.cancel()
        }
        guard context == budgetGeneration, assignmentWorkflow === workflow else { return false }
        beginAssignmentEditing(categoryID: cells[nextIndex].categoryID, month: cells[nextIndex].month)
        return true
    }

    func submitAssignment() async -> Bool {
        guard let budgetID, let selectedCell,
              !assignmentWorkflow.isSubmitting else { return false }
        let context = budgetGeneration
        let workflow = assignmentWorkflow
        guard await workflow.submit(
                  selectedMonth: selectedCell.month,
                  budgetID: budgetID,
                  repository: repository
              ) != nil else { return false }
        guard context == budgetGeneration, assignmentWorkflow === workflow else { return false }
        self.selectedCell = nil
        hardwareInputText = ""
        // Publish all displayed months together, including balances carried
        // forward by the assignment, without changing the navigation anchor.
        _ = await refreshVisibleMonths()
        return true
    }

    func cancelAssignmentEditing() {
        assignmentWorkflow.cancel()
        if !assignmentWorkflow.isPresented {
            selectedCell = nil
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
                .filter { !$0.isIncome && expandedGroupIDs.contains($0.id) }
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
        } catch is CancellationError {
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
                stagedErrors.removeValue(forKey: month)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                stagedErrors[month] = error.localizedDescription
            }
            guard requestGeneration == generation, self.budgetID == id else { return }
        }
        guard requestGeneration == generation, self.budgetID == id else { return }
        monthSnapshots.merge(staged) { _, replacement in replacement }
        for month in staged.keys { monthErrors.removeValue(forKey: month) }
        monthErrors.merge(stagedErrors) { _, replacement in replacement }
        normalizeState(using: visibleMonths.compactMap { staged[$0]?.month }.first)
        trimCache()
    }

    private func normalizeState(using month: BudgetMonth?) {
        guard let month else { return }
        let groups = Set(month.categoryGroups.filter { !$0.isIncome }.map(\.id))
        if expansionInitializedBudgetID == budgetID {
            expandedGroupIDs.formIntersection(groups)
        } else {
            expandedGroupIDs = Set(month.categoryGroups.filter { !$0.isIncome && $0.hidden != true }.map(\.id))
            expansionInitializedBudgetID = budgetID
        }
        if let selectedCell, category(at: selectedCell) == nil {
            self.selectedCell = nil
            assignmentWorkflow = BudgetAssignmentWorkflow()
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
