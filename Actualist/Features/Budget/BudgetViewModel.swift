import Foundation
import Observation

@MainActor
@Observable
final class BudgetViewModel {
    var budgetMonth: BudgetMonth?
    var selectedMonth: String?
    var availableMonths: [String] = []
    private(set) var loadedBudgetID: String?
    private var loadedBudgetAlerts: [BudgetAlert] = []
    var expandedGroupIDs: Set<String> = []
    private var loadGeneration = 0
    var isLoading = true
    var errorMessage: String?
    var currency: BudgetCurrency = .usd
    var includeCarryoverCategoriesInOverspentAlerts = false
    private(set) var isTrackingBudget = false
    private(set) var modeIdentity: BudgetModeIdentity?

    let assignmentWorkflow: BudgetAssignmentWorkflow
    let moveMoneyWorkflow = BudgetMoveMoneyWorkflow()
    let templateWorkflow = BudgetTemplateWorkflow()
    let overspentCoverSelection = OverspentCoverSelectionWorkflow()

    var isCoveringOverspentSelection: Bool {
        overspentCoverSelection.isSubmitting
    }

    init(initialMonth: LoadedBudgetMonth? = nil, initialBudgetID: String? = nil, assignmentWorkflow: BudgetAssignmentWorkflow? = nil) {
        self.assignmentWorkflow = assignmentWorkflow ?? BudgetAssignmentWorkflow()
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
        !isTrackingBudget && overspentCategoryOptions.count >= 2 && !overspentCoverSelection.isSubmitting
    }

    var canOpenOverspentCover: Bool { !isTrackingBudget }

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
        BudgetMonthNavigationPresentation.title(for: selectedMonth)
    }

    var visibleGroups: [BudgetMonthCategoryGroup] {
        budgetMonth?.categoryGroups.filter { !$0.isIncome || isTrackingBudget } ?? []
    }

    var hasMonthTemplateActions: Bool {
        BudgetTemplateActionAvailability.hasMonthActions(
            in: budgetMonth,
            isTrackingBudget: isTrackingBudget
        )
    }

    var overspentCategoryOptions: [BudgetOverspentCategoryOption] {
        BudgetOverspendingPresentation.options(in: budgetMonth, isTrackingBudget: isTrackingBudget,
            includeCarryover: includeCarryoverCategoriesInOverspentAlerts)
    }

    func categoryDetails(for categoryID: String) -> CategoryMonthDetails? {
        guard let selectedMonth,
              let category = budgetMonth?.categoryGroups.flatMap(\.categories).first(where: { $0.id == categoryID }) else { return nil }
        return CategoryMonthDetails(category: category, month: selectedMonth, modeIdentity: modeIdentity)
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

    var preferredMonth: String { YearMonth(date: Date()).rawValue }

    var isAssignmentKeypadPresented: Bool {
        assignmentWorkflow.isPresented
    }

    var activeAssignmentCategoryID: String? {
        assignmentWorkflow.activeCategoryID
    }

    var activeCategoryHasTemplate: Bool {
        BudgetTemplateActionAvailability.hasCategoryAction(
            for: activeAssignmentCategoryID,
            in: visibleGroups
        )
    }

    var activeCategoryMonthDetails: CategoryMonthDetails? {
        guard let categoryID = activeAssignmentCategoryID,
              let selectedMonth,
              let category = category(for: categoryID) else {
            return nil
        }
        return CategoryMonthDetails(
            category: category,
            month: selectedMonth,
            modeIdentity: modeIdentity
        )
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
        activeCategoryHasTemplate && assignmentWorkflow.canApplyCategoryTemplate
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
        let preferred = loadedBudgetID == budgetID ? selectedMonth ?? preferredMonth : preferredMonth
        await loadMonth(budgetID: budgetID, showsLoading: budgetMonth == nil) {
            try await repository.currentBudgetMonth(budgetID: budgetID, preferredMonth: preferred)
        }
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
        assignmentWorkflow.reconcile(budgetID: budgetID, month: month)
        await loadMonth(budgetID: budgetID, showsLoading: true) {
            try await repository.budgetMonth(budgetID: budgetID, selectedMonth: month)
        }
    }

    private func loadMonth(
        budgetID: String, showsLoading: Bool,
        read: () async throws -> LoadedBudgetMonth
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = showsLoading
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let loaded = try await read()
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            apply(loaded, budgetID: budgetID)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.userFacingMessage
        }
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
        guard !isTrackingBudget, let selectedMonth else {
            return false
        }

        let commands = overspentCoverCommands(source: source)
        guard commands.count == selectedOverspentCategoryIDs.count else {
            overspentCoverSelection.finishSubmission(success: false)
            errorMessage = "One or more selected categories are no longer overspent."
            return false
        }

        overspentCoverSelection.markSubmitting()
        let coverGeneration = overspentCoverSelection.currentSubmissionGeneration
        errorMessage = nil

        do {
            let loadedMonth = try await repository.moveMoneyAndRefresh(expectedMode: modeIdentity,
                commands: commands,
                budgetID: budgetID,
                month: selectedMonth
            ) {}
            guard coverGeneration == overspentCoverSelection.currentSubmissionGeneration else { return false }
            guard loadedBudgetID == budgetID,
                  self.selectedMonth == loadedMonth.month.month,
                  loadedMonth.modeIdentity == modeIdentity else {
                _ = overspentCoverSelection.finishSubmission(success: false, expectedGeneration: coverGeneration)
                return false
            }
            _ = overspentCoverSelection.finishSubmission(success: true, expectedGeneration: coverGeneration)
            apply(loadedMonth, budgetID: budgetID)
            return true
        } catch {
            guard coverGeneration == overspentCoverSelection.currentSubmissionGeneration else { return false }
            _ = overspentCoverSelection.finishSubmission(success: false, expectedGeneration: coverGeneration)
            errorMessage = error.userFacingMessage
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

    func beginAssignmentEditing(for category: BudgetMonthCategory) {
        assignmentWorkflow.begin(
            for: category,
            budgetID: loadedBudgetID,
            month: selectedMonth,
            modeIdentity: modeIdentity
        )
    }

    func cancelAssignmentEditing() {
        assignmentWorkflow.cancel()
    }

    func beginMoveMoney() {
        guard !isTrackingBudget else { return }
        guard let categoryID = assignmentWorkflow.activeCategoryID,
              !assignmentWorkflow.isSubmitting,
              let category = category(for: categoryID) else {
            return
        }

        moveMoneyWorkflow.begin(
            for: category,
            budgetID: loadedBudgetID,
            month: selectedMonth,
            modeIdentity: modeIdentity
        )
    }

    func beginMoveMoney(for categoryID: String) {
        guard !isTrackingBudget else { return }
        guard let category = category(for: categoryID) else {
            return
        }

        assignmentWorkflow.cancel()
        moveMoneyWorkflow.begin(
            for: category,
            budgetID: loadedBudgetID,
            month: selectedMonth,
            modeIdentity: modeIdentity
        )
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

    func assignedAmountDisplay(for category: BudgetMonthCategory, randomized: Bool = false) -> BudgetAssignedAmountDisplay {
        assignmentWorkflow.amountDisplay(for: category, currency: currency, randomized: randomized)
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

        guard loadedBudgetID == budgetID,
              selectedMonth == loadedMonth.month.month,
              loadedMonth.modeIdentity == modeIdentity else {
            return false
        }
        apply(loadedMonth, budgetID: budgetID)
        return true
    }

    func applyMonthTemplate(
        _ mode: BudgetTemplateApplicationMode,
        expectedMode: BudgetModeIdentity? = nil,
        using appState: AppState
    ) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.budgetRepository

        let command: BudgetTemplateCommand = mode == .overwrite ? .overwrite : .fillEmpty
        return await applyMonthTemplate(command, budgetID: budgetID, expectedMode: expectedMode, repository: repository)
    }

    func applyMonthTemplate(
        _ command: BudgetTemplateCommand,
        budgetID: String,
        expectedMode: BudgetModeIdentity? = nil,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        if let expectedMode, expectedMode != modeIdentity {
            errorMessage = BudgetModeWriteError.budgetChanged.localizedDescription
            return false
        }
        guard let selectedMonth,
              !templateWorkflow.isApplying else {
            return false
        }

        let reviewedMode = expectedMode ?? modeIdentity
        errorMessage = nil
        let request = templateWorkflow.beginRequest(
            budgetID: budgetID,
            month: selectedMonth,
            modeIdentity: reviewedMode
        )
        switch await templateWorkflow.apply(
            command: command,
            selectedMonth: selectedMonth,
            budgetID: budgetID,
            expectedMode: reviewedMode,
            repository: repository
        ) {
        case .success(let loadedMonth):
            guard templateWorkflow.isCurrent(
                request,
                currentBudgetID: loadedBudgetID,
                currentMonth: selectedMonth,
                currentModeIdentity: modeIdentity
            ), loadedMonth.modeIdentity == request.modeIdentity else {
                return false
            }
            apply(loadedMonth, budgetID: budgetID)
            errorMessage = nil
            return true
        case .failure(let error):
            guard templateWorkflow.isCurrent(
                request,
                currentBudgetID: loadedBudgetID,
                currentMonth: selectedMonth,
                currentModeIdentity: modeIdentity
            ) else {
                // A stale failure must not surface as an error for the current
                // context.
                return false
            }
            errorMessage = error.userFacingMessage
            return false
        }
    }

    func applyCategoryTemplate(
        expectedMode: BudgetModeIdentity? = nil,
        using appState: AppState
    ) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.budgetRepository

        return await applyCategoryTemplate(budgetID: budgetID, expectedMode: expectedMode, repository: repository)
    }

    func applyCategoryTemplate(
        budgetID: String,
        expectedMode: BudgetModeIdentity? = nil,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        if let expectedMode, expectedMode != modeIdentity {
            errorMessage = BudgetModeWriteError.budgetChanged.localizedDescription
            return false
        }
        guard let selectedMonth,
              let loadedMonth = await assignmentWorkflow.applyCategoryTemplate(
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                expectedMode: expectedMode,
                repository: repository
              ) else {
            return false
        }

        guard loadedBudgetID == budgetID, selectedMonth == loadedMonth.month.month else { return false }
        apply(loadedMonth, budgetID: budgetID)
        errorMessage = nil
        return true
    }

    func submitMoveMoney(using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else { return false }
        return await submitMoveMoney(budgetID: budgetID, repository: appState.budgetRepository)
    }

    func submitMoveMoney(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard let selectedMonth,
              let loadedMonth = await moveMoneyWorkflow.submit(
                selectedMonth: selectedMonth, budgetID: budgetID, repository: repository
              ), loadedBudgetID == budgetID,
              loadedMonth.month.month == selectedMonth,
              loadedMonth.modeIdentity == modeIdentity else {
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

    private func apply(_ loadedMonth: LoadedBudgetMonth, budgetID: String? = nil) {
        if budgetMonth != nil, modeIdentity != loadedMonth.modeIdentity {
            assignmentWorkflow.invalidate()
            moveMoneyWorkflow.invalidate()
            overspentCoverSelection.endSelection()
        }
        if let budgetID {
            assignmentWorkflow.reconcile(budgetID: budgetID, categoryIDs: Set(loadedMonth.month.categoryGroups.flatMap(\.categories).map(\.id)))
        }
        templateWorkflow.noteSelectionChange()
        let modeChanged = isTrackingBudget != loadedMonth.isTrackingBudget
        let currentMonth = budgetMonth?.month ?? selectedMonth
        let isSameMonth = currentMonth == loadedMonth.month.month
        let isSameBudget = loadedBudgetID == nil || budgetID == nil || loadedBudgetID == budgetID
        if let budgetID {
            loadedBudgetID = budgetID
        }
        availableMonths = BudgetMonthNavigationPresentation.pickerMonths(for: loadedMonth)
        budgetMonth = loadedMonth.month
        selectedMonth = loadedMonth.month.month
        currency = loadedMonth.currency
        isTrackingBudget = loadedMonth.isTrackingBudget
        modeIdentity = loadedMonth.modeIdentity
        loadedBudgetAlerts = loadedMonth.alerts.compactMap {
            BudgetAlert(alert: $0, currency: loadedMonth.currency)
        }
        if isSameBudget && isSameMonth && !modeChanged {
            let loadedGroupIDs = Set(loadedMonth.month.categoryGroups.map(\.id))
            expandedGroupIDs = expandedGroupIDs.intersection(loadedGroupIDs)
        } else {
            expandedGroupIDs = Set(
                loadedMonth.month.categoryGroups
                    .filter { (!$0.isIncome || isTrackingBudget) && $0.hidden != true }
                    .map(\.id)
            )
        }
        overspentCoverSelection.intersectSelection(with: Set(overspentCategoryOptions.map(\.id)))
    }

    private func category(for categoryID: String) -> BudgetMonthCategory? {
        visibleGroups
            .flatMap(\.visibleCategories)
            .first { $0.id == categoryID }
    }

    static let maxAssignmentDigits = BudgetAssignmentWorkflow.maxInputDigits
}
