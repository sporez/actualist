import Foundation
import Observation

@MainActor
@Observable
final class BudgetViewModel {
    var budgetMonth: BudgetMonth?
    var selectedMonth: String?
    var availableMonths: [String] = []
    private var loadedBudgetID: String?
    private var loadedBudgetAlerts: [BudgetAlert] = []
    var expandedGroupIDs: Set<String> = []
    var isLoading = true
    var errorMessage: String?
    var currency: BudgetCurrency = .usd
    var includeCarryoverCategoriesInOverspentAlerts = false
    /// Envelope (false) vs tracking (true). Drives the overspent hidden rule.
    private(set) var isTrackingBudget = false

    let assignmentWorkflow = BudgetAssignmentWorkflow()
    let moveMoneyWorkflow = BudgetMoveMoneyWorkflow()
    let templateWorkflow = BudgetTemplateWorkflow()
    let overspentCoverSelection = OverspentCoverSelectionWorkflow()

    var isCoveringOverspentSelection: Bool {
        overspentCoverSelection.isSubmitting
    }

    var isMoveMoneySubmitting: Bool {
        moveMoneyWorkflow.isSubmitting
    }

    init(initialMonth: LoadedBudgetMonth? = nil, initialBudgetID: String? = nil) {
        loadedBudgetID = initialBudgetID
        guard let initialMonth else {
            return
        }
        apply(initialMonth, budgetID: initialBudgetID)
        isLoading = false
    }

    var assignmentDraft: BudgetAssignmentDraft? {
        assignmentWorkflow.draft
    }

    var moveMoneyDraft: BudgetMoveMoneyDraft? {
        moveMoneyWorkflow.draft
    }

    var monthTemplateSubmissionState: BudgetAssignmentSubmissionState {
        templateWorkflow.submissionState
    }

    var canBeginOverspentCoverSelection: Bool {
        overspentCategoryOptions.count >= 2 && !overspentCoverSelection.isSubmitting
    }

    var isOverspentCoverSelecting: Bool {
        overspentCoverSelection.isSelecting
    }

    var selectedOverspentCategoryIDs: Set<String> {
        overspentCoverSelection.selectedCategoryIDs
    }

    var canSubmitOverspentCoverSelection: Bool {
        overspentCoverSelection.canSubmitSelection
    }

    var navigationTitle: String {
        guard let selectedMonth else {
            return Self.title(for: Date())
        }

        return Self.title(forMonthIdentifier: selectedMonth)
    }

    var visibleGroups: [BudgetMonthCategoryGroup] {
        budgetMonth?.categoryGroups.filter { !$0.isIncome } ?? []
    }

    var overspentCategoryOptions: [BudgetOverspentCategoryOption] {
        visibleGroups.flatMap { group -> [BudgetOverspentCategoryOption] in
            let categories = BudgetCategoryVisibility.overspentCategories(
                in: group,
                isTrackingBudget: isTrackingBudget
            )
            return categories.compactMap { category -> BudgetOverspentCategoryOption? in
                guard category.balance < 0,
                      includeCarryoverCategoriesInOverspentAlerts || !category.carryover else {
                    return nil
                }

                return BudgetOverspentCategoryOption(
                    id: category.id,
                    groupName: group.name,
                    category: category
                )
            }
        }
    }

    var budgetAlerts: [BudgetAlert] {
        let overspentCount = overspentCategoryOptions.count

        return loadedBudgetAlerts.compactMap { alert in
            guard alert.kind == .overspending else {
                return alert
            }
            guard overspentCount > 0 else {
                return nil
            }

            return alert.replacingCount(with: overspentCount)
        }
    }

    var overspendingAlertCount: Int? {
        guard let budgetMonth else {
            return nil
        }

        let overspentCategoryCount = overspentCategoryOptions.count
        if overspentCategoryCount > 0 {
            return overspentCategoryCount
        }

        return budgetMonth.lastMonthOverspent < 0 ? 1 : nil
    }

    var preferredMonth: String {
        YearMonth(date: Date()).rawValue
    }

    var isAssignmentKeypadPresented: Bool {
        assignmentWorkflow.isPresented
    }

    var activeAssignmentCategoryID: String? {
        assignmentWorkflow.activeCategoryID
    }

    var activeCategoryMonthDetails: CategoryMonthDetails? {
        guard let categoryID = activeAssignmentCategoryID,
              let selectedMonth,
              let category = category(for: categoryID) else {
            return nil
        }
        return CategoryMonthDetails(category: category, month: selectedMonth)
    }

    var canSubmitAssignment: Bool {
        assignmentWorkflow.canSubmit
    }

    var activeAssignmentErrorMessage: String? {
        assignmentWorkflow.errorMessage
    }

    var isSubmittingAssignment: Bool {
        assignmentWorkflow.isSubmitting
    }

    var canApplyCategoryTemplate: Bool {
        assignmentWorkflow.canApplyCategoryTemplate
    }

    var isApplyingMonthTemplate: Bool {
        templateWorkflow.isApplying
    }

    var isMoveMoneyPresented: Bool {
        moveMoneyWorkflow.isPresented
    }

    var canSubmitMoveMoney: Bool {
        moveMoneyWorkflow.canSubmit
    }

    var isSubmittingMoveMoney: Bool {
        moveMoneyWorkflow.isSubmitting
    }

    var activeMoveMoneyErrorMessage: String? {
        moveMoneyWorkflow.errorMessage
    }

    var moveMoneyAmountDollars: Double {
        moveMoneyWorkflow.amountDollars(using: currency)
    }

    var moveMoneyMaximumDollars: Double {
        currency.displayUnits(fromMinorUnits: max(moveMoneyMaximumAmount, 1))
    }

    var moveMoneyMaximumAmount: Int {
        moveMoneyWorkflow.maximumAmount(
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups
        )
    }

    var moveMoneyAvailableDisplayAmount: Int {
        moveMoneyWorkflow.availableDisplayAmount()
    }

    var moveMoneyCounterpartyAvailableDisplayAmount: Int {
        moveMoneyWorkflow.counterpartyAvailableDisplayAmount(
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups
        )
    }

    var moveMoneyDisplayAmount: Int {
        moveMoneyWorkflow.displayAmount
    }

    var moveMoneySliderDetentFeedback: Int {
        moveMoneyWorkflow.sliderDetentFeedback
    }

    func moveMoneySliderSpec(for allocationID: String? = nil) -> BudgetMoveMoneySliderSpec {
        moveMoneyWorkflow.sliderSpec(
            for: allocationID,
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups,
            currency: currency
        )
    }

    func setMoveMoneySliderEditing(_ isEditing: Bool, allocationID: String? = nil) {
        moveMoneyWorkflow.setSliderEditing(
            isEditing,
            allocationID: allocationID,
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups
        )
    }

    func setMoveMoneySliderAmountDollars(_ value: Double, allocationID: String? = nil) {
        moveMoneyWorkflow.setSliderAmountDollars(
            value,
            allocationID: allocationID,
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups,
            currency: currency
        )
    }

    var hasPendingMoveMoneyCoverIntro: Bool {
        moveMoneyWorkflow.hasPendingCoverIntro
    }

    func playMoveMoneyCoverIntro() async {
        await moveMoneyWorkflow.playCoverIntro()
    }

    func load(using appState: AppState) async {
        includeCarryoverCategoriesInOverspentAlerts =
            appState.settings.includeCarryoverCategoriesInOverspentAlerts

        guard let budgetID = appState.settings.selectedBudgetID else {
            isLoading = false
            return
        }
        let repository = appState.budgetRepository

        await load(budgetID: budgetID, repository: repository)
    }

    func refresh(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.budgetRepository

        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        if let selectedMonth {
            await selectMonth(selectedMonth, budgetID: budgetID, repository: repository)
        } else {
            await load(budgetID: budgetID, repository: repository)
        }
    }

    func load(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        isLoading = budgetMonth == nil
        errorMessage = nil

        do {
            let loadedMonth = try await repository.currentBudgetMonth(
                budgetID: budgetID,
                preferredMonth: preferredMonth
            )
            apply(loadedMonth, budgetID: budgetID)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func selectMonth(_ month: String, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.budgetRepository

        await selectMonth(month, budgetID: budgetID, repository: repository)
    }

    func refreshSelectedMonth(using appState: AppState) async {
        guard let selectedMonth else {
            await load(using: appState)
            return
        }

        await selectMonth(selectedMonth, using: appState)
    }

    func selectMonth(
        _ month: String,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let loadedMonth = try await repository.budgetMonth(
                budgetID: budgetID,
                selectedMonth: month
            )
            apply(loadedMonth, budgetID: budgetID)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func isExpanded(_ group: BudgetMonthCategoryGroup) -> Bool {
        expandedGroupIDs.contains(group.id)
    }

    func toggle(_ group: BudgetMonthCategoryGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    func beginOverspentCoverSelection() {
        overspentCoverSelection.beginSelection(
            eligibleIDs: overspentCategoryOptions.map(\.id)
        )
    }

    func endOverspentCoverSelection() {
        overspentCoverSelection.endSelection()
    }

    func toggleOverspentCoverSelection(_ option: BudgetOverspentCategoryOption) {
        overspentCoverSelection.toggleSelection(option.id, isEligible: true)
    }

    // Selected categories are excluded from single-cover eligible sources, so
    // the shared source can never double as a cover destination.
    func overspentCoverCommands(
        source: BudgetOverspentCoverSource
    ) -> [BudgetMoveMoneyCommand] {
        overspentCoverSelection.coverCommands(
            options: overspentCategoryOptions,
            source: source
        )
    }

    func coverOverspentSelection(
        source: BudgetOverspentCoverSource,
        using appState: AppState
    ) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.budgetRepository

        return await coverOverspentSelection(
            source: source,
            budgetID: budgetID,
            repository: repository
        )
    }

    func coverOverspentSelection(
        source: BudgetOverspentCoverSource,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard let selectedMonth else {
            return false
        }

        let commands = overspentCoverCommands(source: source)
        guard commands.count == selectedOverspentCategoryIDs.count else {
            overspentCoverSelection.finishSubmission(success: false)
            errorMessage = "One or more selected categories are no longer overspent."
            return false
        }

        overspentCoverSelection.markSubmitting()
        errorMessage = nil

        do {
            let loadedMonth = try await repository.moveMoneyAndRefresh(
                commands: commands,
                budgetID: budgetID,
                month: selectedMonth
            ) {}
            overspentCoverSelection.finishSubmission(success: true)
            apply(loadedMonth, budgetID: budgetID)
            return true
        } catch {
            overspentCoverSelection.finishSubmission(success: false)
            errorMessage = error.localizedDescription
            return false
        }
    }

    // Source candidates for the multi-cover picker. Reuses `BudgetMonth`'s
    // editor category groups so the synthetic "To Budget" (available income)
    // source appears exactly as it does in the transaction editor's category
    // picker, then removes categories that are selected destinations or
    // currently overspent. Covering overspent categories from another overspent
    // one would just move the red balance.
    func overspentCoverSourcePickerGroups() -> [TransactionEditorCategoryGroup] {
        let selectedIDs = selectedOverspentCategoryIDs
        let selectedOverspentIDs = Set(overspentCategoryOptions.map(\.id))
        let baseGroups = budgetMonth?.editorCategoryGroups(currency: currency) ?? []
        return baseGroups.compactMap { group -> TransactionEditorCategoryGroup? in
            // "To Budget" represents available income, not an expense category,
            // so it is always a valid cover source.
            if group.id == BudgetMoveMoneyDestination.toBudget.id {
                return group
            }
            let options = group.options.filter { option in
                !selectedIDs.contains(option.id) && !selectedOverspentIDs.contains(option.id)
            }
            guard !options.isEmpty else {
                return nil
            }
            return TransactionEditorCategoryGroup(id: group.id, name: group.name, options: options)
        }
    }

    // Maps a selected picker option back to the cover source it represents. The
    // "To Budget" option is synthetic (its title is the reserved
    // `BudgetMoveMoneyDestination.toBudget.title`), so it routes to `.toBudget`;
    // every other option is a real expense category.
    func coverSource(
        for option: TransactionEditorCategoryOption
    ) -> BudgetOverspentCoverSource {
        if option.title == BudgetMoveMoneyDestination.toBudget.title {
            return .toBudget
        }
        return .category(id: option.id, name: option.title)
    }

    func fundingSourceOptions() -> [BudgetMoveMoneyDestinationGroup] {
        moveMoneyWorkflow.destinationGroups(
            matching: "",
            visibleGroups: visibleGroups.filter { group in
                group.visibleCategories.contains { category in
                    !overspentCoverSelection.selectedCategoryIDs.contains(category.id)
                }
            },
            currency: currency
        ).map { group in
            var filtered = group
            filtered.options = group.options.filter { option in
                !overspentCoverSelection.selectedCategoryIDs.contains(option.id)
            }
            return filtered
        }.filter { !$0.options.isEmpty }
    }

    func beginAssignmentEditing(for category: BudgetMonthCategory) {
        assignmentWorkflow.begin(for: category)
    }

    func cancelAssignmentEditing() {
        assignmentWorkflow.cancel()
    }

    func beginMoveMoney() {
        guard let categoryID = assignmentWorkflow.activeCategoryID,
              !assignmentWorkflow.isSubmitting,
              let category = category(for: categoryID) else {
            return
        }

        moveMoneyWorkflow.begin(for: category)
    }

    func beginMoveMoney(for categoryID: String) {
        guard let category = category(for: categoryID) else {
            return
        }

        assignmentWorkflow.cancel()
        moveMoneyWorkflow.begin(for: category)
    }

    func cancelMoveMoney() {
        moveMoneyWorkflow.cancel()
    }

    func setMoveMoneyAmountDollars(_ value: Double) {
        moveMoneyWorkflow.setAmountDollars(value, currency: currency)
    }

    func appendMoveMoneyDigit(_ digit: Int) {
        moveMoneyWorkflow.appendDigit(digit)
    }

    func deleteMoveMoneyDigit() {
        moveMoneyWorkflow.deleteDigit()
    }

    func clearMoveMoneyAmount() {
        moveMoneyWorkflow.clearAmount()
    }

    func selectMoveMoneyDestination(_ destination: BudgetMoveMoneyDestination) {
        moveMoneyWorkflow.selectDestination(destination)
    }

    func toggleMoveMoneyDestination(_ destination: BudgetMoveMoneyDestination) {
        moveMoneyWorkflow.toggleDestination(destination)
    }

    func isMoveMoneyDestinationSelected(_ destination: BudgetMoveMoneyDestination) -> Bool {
        moveMoneyWorkflow.isDestinationSelected(destination)
    }

    func finalizeMoveMoneyDestinationSelection() {
        moveMoneyWorkflow.finalizeDestinationSelection()
    }

    func setFocusedMoveMoneyAllocation(_ id: String) {
        moveMoneyWorkflow.setFocusedAllocation(id)
    }

    func toggleMoveMoneyDirection() {
        moveMoneyWorkflow.toggleDirection()
    }

    func appendAssignmentDigit(_ digit: Int) {
        assignmentWorkflow.appendDigit(digit)
    }

    func deleteAssignmentDigit() {
        assignmentWorkflow.deleteDigit()
    }

    func clearOrCancelAssignmentInput() {
        assignmentWorkflow.clearInputOrCancel()
    }

    func setAssignmentInputMode(_ mode: BudgetAssignmentInputMode) {
        assignmentWorkflow.setInputMode(mode)
    }

    func assignedAmountDisplay(for category: BudgetMonthCategory) -> BudgetAssignedAmountDisplay {
        assignmentWorkflow.amountDisplay(for: category, currency: currency)
    }

    func isEditingAssignment(for category: BudgetMonthCategory) -> Bool {
        assignmentWorkflow.isEditing(category)
    }

    func submitAssignment(using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.budgetRepository

        return await submitAssignment(budgetID: budgetID, repository: repository)
    }

    func submitAssignment(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard let selectedMonth,
              let loadedMonth = await assignmentWorkflow.submit(
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
              ) else {
            return false
        }

        apply(loadedMonth, budgetID: budgetID)
        return true
    }

    func applyMonthTemplate(
        _ mode: BudgetTemplateApplicationMode,
        using appState: AppState
    ) async -> Bool {
        guard appState.canApplyBudgetTemplates,
              let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.budgetRepository

        let command: BudgetTemplateCommand = mode == .overwrite ? .overwrite : .fillEmpty
        return await applyMonthTemplate(command, budgetID: budgetID, repository: repository)
    }

    func applyMonthTemplate(
        _ command: BudgetTemplateCommand,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard let selectedMonth,
              !templateWorkflow.isApplying else {
            return false
        }

        errorMessage = nil
        // Capture the request identity so a refresh returning after the user
        // navigated to a different month/budget (or after a newer request) is
        // detected as stale. The write still targets the captured month and
        // syncs normally; only the returned refresh is dropped. See
        // `BudgetTemplateWorkflow.beginRequest`/`isCurrent`.
        let request = templateWorkflow.beginRequest(budgetID: budgetID, month: selectedMonth)
        switch await templateWorkflow.apply(
            command: command,
            selectedMonth: selectedMonth,
            budgetID: budgetID,
            repository: repository
        ) {
        case .success(let loadedMonth):
            guard templateWorkflow.isCurrent(
                request,
                currentBudgetID: loadedBudgetID,
                currentMonth: selectedMonth
            ) else {
                templateWorkflow.discardStaleResult()
                return false
            }
            apply(loadedMonth, budgetID: budgetID)
            errorMessage = nil
            return true
        case .failure(let error):
            guard templateWorkflow.isCurrent(
                request,
                currentBudgetID: loadedBudgetID,
                currentMonth: selectedMonth
            ) else {
                // A stale failure must not surface as an error for the current
                // context.
                templateWorkflow.discardStaleResult()
                return false
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func applyCategoryTemplate(using appState: AppState) async -> Bool {
        guard appState.canApplyBudgetTemplates,
              let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.budgetRepository

        return await applyCategoryTemplate(budgetID: budgetID, repository: repository)
    }

    func applyCategoryTemplate(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard let selectedMonth,
              let loadedMonth = await assignmentWorkflow.applyCategoryTemplate(
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
              ) else {
            return false
        }

        apply(loadedMonth, budgetID: budgetID)
        errorMessage = nil
        return true
    }

    func submitMoveMoney(using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.budgetRepository

        return await submitMoveMoney(budgetID: budgetID, repository: repository)
    }

    func submitMoveMoney(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard let selectedMonth,
              let loadedMonth = await moveMoneyWorkflow.submit(
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
              ) else {
            return false
        }

        apply(loadedMonth, budgetID: budgetID)
        assignmentWorkflow.resetAfterRelatedWorkflow()
        return true
    }

    func moveMoneyDestinationGroups(matching searchText: String) -> [BudgetMoveMoneyDestinationGroup] {
        moveMoneyWorkflow.destinationGroups(
            matching: searchText,
            visibleGroups: visibleGroups,
            currency: currency
        )
    }

    func toBudgetDestinationOption() -> BudgetMoveMoneyDestinationOption {
        BudgetMoveMoneyDestinationOption(
            id: "to-budget",
            title: "To Budget",
            amount: budgetMonth?.toBudget ?? 0,
            valueText: currency.formatted(budgetMonth?.toBudget ?? 0),
            destination: .toBudget
        )
    }

    private static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private static func title(forMonthIdentifier month: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM"
        guard let date = input.date(from: month) else {
            return month
        }

        return title(for: date)
    }

    private func apply(_ loadedMonth: LoadedBudgetMonth, budgetID: String? = nil) {
        // Any selection/state change supersedes an in-flight template request:
        // tell the template workflow so a stale refresh returning later is
        // detected by `isCurrent` and discarded instead of overwriting the UI.
        templateWorkflow.noteSelectionChange()
        let currentMonth = budgetMonth?.month ?? selectedMonth
        let isSameMonth = currentMonth == loadedMonth.month.month
        let isSameBudget = loadedBudgetID == nil || budgetID == nil || loadedBudgetID == budgetID
        let previousExpandedGroupIDs = expandedGroupIDs
        if let budgetID {
            loadedBudgetID = budgetID
        }
        availableMonths = Self.monthPickerMonths(for: loadedMonth)
        budgetMonth = loadedMonth.month
        selectedMonth = loadedMonth.month.month
        currency = loadedMonth.currency
        isTrackingBudget = loadedMonth.isTrackingBudget
        loadedBudgetAlerts = loadedMonth.alerts.compactMap {
            BudgetAlert(alert: $0, currency: loadedMonth.currency)
        }
        if isSameBudget && isSameMonth {
            let loadedGroupIDs = Set(loadedMonth.month.categoryGroups.map(\.id))
            expandedGroupIDs = previousExpandedGroupIDs.intersection(loadedGroupIDs)
        } else {
            expandedGroupIDs = Set(
                loadedMonth.month.categoryGroups
                    .filter { !$0.isIncome }
                    .map(\.id)
            )
        }
        overspentCoverSelection.intersectSelection(with: Set(
            OverspentCoverSelectionViewModel.overspentOptions(
                for: loadedMonth.month,
                includeCarryover: includeCarryoverCategoriesInOverspentAlerts
            ).map(\.id)
        ))
    }

    private static func monthPickerMonths(for loadedMonth: LoadedBudgetMonth) -> [String] {
        let loadedIDs = loadedMonth.availableMonths.compactMap(canonicalMonthID)
        let selectedIDs = [loadedMonth.selectedMonth, loadedMonth.month.month].compactMap(canonicalMonthID)
        return Array(Set(loadedIDs + selectedIDs)).sorted()
    }

    private static func canonicalMonthID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split { character in
            character == "-" || character == "/" || character == "."
        }
        if parts.count >= 2,
           let year = Int(parts[0]),
           let month = Int(parts[1]),
           let monthID = canonicalMonthID(year: year, month: month) {
            return monthID
        }

        let digits = String(trimmed.prefix { $0.isNumber })
        guard digits.count >= 6 else {
            return nil
        }

        let yearEnd = digits.index(digits.startIndex, offsetBy: 4)
        let monthEnd = digits.index(yearEnd, offsetBy: 2)
        guard let year = Int(digits[..<yearEnd]),
              let month = Int(digits[yearEnd..<monthEnd]) else {
            return nil
        }

        return canonicalMonthID(year: year, month: month)
    }

    private static func canonicalMonthID(year: Int, month: Int) -> String? {
        guard (1900...9999).contains(year), (1...12).contains(month) else {
            return nil
        }

        return String(format: "%04d-%02d", year, month)
    }

    private func category(for categoryID: String) -> BudgetMonthCategory? {
        visibleGroups
            .flatMap(\.visibleCategories)
            .first { $0.id == categoryID }
    }

    static let maxAssignmentDigits = BudgetAssignmentWorkflow.maxInputDigits
}
