import Foundation
import Observation

@MainActor
@Observable
final class BudgetViewModel {
    var budgetMonth: BudgetMonth?
    var selectedMonth: String?
    var availableMonths: [String] = []
    var budgetAlerts: [BudgetAlert] = []
    var expandedGroupIDs: Set<String> = []
    var isLoading = false
    var errorMessage: String?
    var assignmentDraft: BudgetAssignmentDraft?
    var moveMoneyDraft: BudgetMoveMoneyDraft?
    var monthTemplateSubmissionState: BudgetAssignmentSubmissionState = .draft

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
        visibleGroups.flatMap { group in
            group.visibleCategories.compactMap { category in
                guard category.balance < 0 else {
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

    var overspendingAlertCount: Int? {
        guard let budgetMonth else {
            return nil
        }

        let overspentCategoryCount = visibleGroups
            .flatMap(\.visibleCategories)
            .filter { $0.balance < 0 }
            .count

        if overspentCategoryCount > 0 {
            return overspentCategoryCount
        }

        return budgetMonth.lastMonthOverspent < 0 ? 1 : nil
    }

    var preferredMonth: String {
        YearMonth(date: Date()).rawValue
    }

    var isAssignmentKeypadPresented: Bool {
        assignmentDraft != nil
    }

    var activeAssignmentCategoryID: String? {
        assignmentDraft?.categoryID
    }

    var canSubmitAssignment: Bool {
        guard let assignmentDraft else {
            return false
        }

        return !assignmentDraft.inputDigits.isEmpty && !assignmentDraft.isSubmitting
    }

    var activeAssignmentErrorMessage: String? {
        guard let assignmentDraft else {
            return nil
        }

        if case .failed(let message) = assignmentDraft.submissionState {
            return message
        }

        return nil
    }

    var isSubmittingAssignment: Bool {
        assignmentDraft?.isSubmitting == true
    }

    var canApplyCategoryTemplate: Bool {
        guard let assignmentDraft else {
            return false
        }

        return !assignmentDraft.isSubmitting
    }

    var isApplyingMonthTemplate: Bool {
        monthTemplateSubmissionState.isSubmitting
    }

    var isMoveMoneyPresented: Bool {
        moveMoneyDraft != nil
    }

    var canSubmitMoveMoney: Bool {
        guard let moveMoneyDraft else {
            return false
        }

        if !moveMoneyDraft.allocations.isEmpty {
            return moveMoneyDraft.totalAllocatedAmount > 0 && !moveMoneyDraft.isSubmitting
        }

        return moveMoneyDraft.amount > 0 && moveMoneyDraft.destination != nil && !moveMoneyDraft.isSubmitting
    }

    var isSubmittingMoveMoney: Bool {
        moveMoneyDraft?.isSubmitting == true
    }

    var activeMoveMoneyErrorMessage: String? {
        guard let moveMoneyDraft else {
            return nil
        }

        if case .failed(let message) = moveMoneyDraft.submissionState {
            return message
        }

        return nil
    }

    var moveMoneyAmountDollars: Double {
        guard let draft = moveMoneyDraft else {
            return 0
        }

        if let allocation = focusedAllocation(in: draft) {
            return Double(allocation.amount) / 100
        }

        return Double(draft.amount) / 100
    }

    var moveMoneyMaximumDollars: Double {
        Double(moveMoneyMaximumAmount) / 100
    }

    var moveMoneyMaximumAmount: Int {
        guard let draft = moveMoneyDraft else {
            return 0
        }

        return moveMoneyMaximumAmount(for: draft)
    }

    var moveMoneyAvailableDisplayAmount: Int {
        guard let draft = moveMoneyDraft else {
            return 0
        }

        let moveAmount = moveMoneyDisplayAmount

        switch draft.direction {
        case .outOfFocusedCategory:
            return draft.focusedAvailable - moveAmount
        case .intoFocusedCategory:
            return draft.focusedAvailable + moveAmount
        }
    }

    var moveMoneyCounterpartyAvailableDisplayAmount: Int {
        guard let draft = moveMoneyDraft,
              let destination = draft.destination else {
            return 0
        }

        let destinationAvailable = availableAmount(for: destination)
        switch draft.direction {
        case .outOfFocusedCategory:
            return destinationAvailable + draft.amount
        case .intoFocusedCategory:
            return destinationAvailable - draft.amount
        }
    }

    var moveMoneyDisplayAmount: Int {
        guard let draft = moveMoneyDraft else {
            return 0
        }

        return draft.allocations.isEmpty ? draft.amount : draft.totalAllocatedAmount
    }

    func load(using appState: AppState) async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return
        }

        await appState.refreshLocalFirstData(budgetID: budgetID)
        await load(budgetID: budgetID, repository: repository)
    }

    func load(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let loadedMonth = try await repository.currentBudgetMonth(
                budgetID: budgetID,
                preferredMonth: preferredMonth
            )
            apply(loadedMonth)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func selectMonth(_ month: String, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return
        }

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
            apply(loadedMonth)
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

    func beginAssignmentEditing(for category: BudgetMonthCategory) {
        guard assignmentDraft?.isSubmitting != true else {
            return
        }

        assignmentDraft = BudgetAssignmentDraft(
            categoryID: category.id,
            originalBudgeted: category.budgeted,
            inputDigits: "",
            inputMode: .direct
        )
    }

    func cancelAssignmentEditing() {
        guard assignmentDraft?.isSubmitting != true else {
            return
        }

        assignmentDraft = nil
    }

    func beginMoveMoney() {
        guard let assignmentDraft,
              assignmentDraft.isSubmitting != true,
              moveMoneyDraft?.isSubmitting != true,
              let category = category(for: assignmentDraft.categoryID) else {
            return
        }

        moveMoneyDraft = makeMoveMoneyDraft(for: category)
    }

    func beginMoveMoney(for categoryID: String) {
        guard moveMoneyDraft?.isSubmitting != true,
              let category = category(for: categoryID) else {
            return
        }

        assignmentDraft = nil
        moveMoneyDraft = makeMoveMoneyDraft(for: category)
    }

    func cancelMoveMoney() {
        guard moveMoneyDraft?.isSubmitting != true else {
            return
        }

        moveMoneyDraft = nil
    }

    func setMoveMoneyAmountDollars(_ value: Double) {
        guard var draft = editableMoveMoneyDraft else {
            return
        }

        let amount = Int((max(0, value) * 100).rounded())
        setFocusedMoveMoneyAmount(amount, draft: &draft)
        moveMoneyDraft = draft
    }

    func appendMoveMoneyDigit(_ digit: Int) {
        guard var draft = editableMoveMoneyDraft,
              (0...9).contains(digit) else {
            return
        }

        setFocusedMoveMoneyAmount(focusedMoveMoneyAmount(in: draft) * 10 + digit, draft: &draft)
        moveMoneyDraft = draft
    }

    func deleteMoveMoneyDigit() {
        guard var draft = editableMoveMoneyDraft else {
            return
        }

        setFocusedMoveMoneyAmount(focusedMoveMoneyAmount(in: draft) / 10, draft: &draft)
        moveMoneyDraft = draft
    }

    func clearMoveMoneyAmount() {
        guard var draft = editableMoveMoneyDraft else {
            return
        }

        setFocusedMoveMoneyAmount(0, draft: &draft)
        moveMoneyDraft = draft
    }

    func selectMoveMoneyDestination(_ destination: BudgetMoveMoneyDestination) {
        guard var draft = editableMoveMoneyDraft else {
            return
        }

        draft.destination = destination
        draft.allocations = []
        draft.focusedAllocationID = nil
        setMoveMoneyAmount(draft.amount, draft: &draft)
        moveMoneyDraft = draft
    }

    func toggleMoveMoneyDestination(_ destination: BudgetMoveMoneyDestination) {
        guard var draft = editableMoveMoneyDraft else {
            return
        }

        draft.destination = nil
        if let index = draft.allocations.firstIndex(where: { $0.id == destination.id }) {
            draft.allocations.remove(at: index)
            if draft.focusedAllocationID == destination.id {
                draft.focusedAllocationID = draft.allocations.last?.id
            }
        } else {
            draft.allocations.append(
                BudgetMoveMoneyAllocation(
                    id: destination.id,
                    destination: destination,
                    amount: 0
                )
            )
            draft.focusedAllocationID = destination.id
        }

        moveMoneyDraft = draft
    }

    func isMoveMoneyDestinationSelected(_ destination: BudgetMoveMoneyDestination) -> Bool {
        moveMoneyDraft?.allocations.contains { $0.id == destination.id } == true
    }

    func finalizeMoveMoneyDestinationSelection() {
        guard var draft = editableMoveMoneyDraft else {
            return
        }

        if draft.allocations.count == 1, let allocation = draft.allocations.first {
            draft.destination = allocation.destination
            draft.amount = allocation.amount
            draft.allocations = []
            draft.focusedAllocationID = nil
        }

        moveMoneyDraft = draft
    }

    func setFocusedMoveMoneyAllocation(_ id: String) {
        guard var draft = editableMoveMoneyDraft,
              draft.allocations.contains(where: { $0.id == id }) else {
            return
        }

        draft.focusedAllocationID = id
        moveMoneyDraft = draft
    }

    func toggleMoveMoneyDirection() {
        guard var draft = editableMoveMoneyDraft else {
            return
        }

        draft.direction = draft.direction.toggled
        setMoveMoneyAmount(draft.amount, draft: &draft)
        draft.allocations = draft.allocations.map { allocation in
            var updated = allocation
            updated.amount = max(0, updated.amount)
            return updated
        }
        moveMoneyDraft = draft
    }

    func appendAssignmentDigit(_ digit: Int) {
        guard var draft = editableAssignmentDraft,
              (0...9).contains(digit) else {
            return
        }

        let candidate = Self.normalizedAssignmentDigits(draft.inputDigits + String(digit))
        // Cap length so the accumulated value can never overflow Int (and stays a sane amount).
        guard candidate.count <= Self.maxAssignmentDigits else {
            return
        }

        draft.inputDigits = candidate
        assignmentDraft = draft
    }

    func deleteAssignmentDigit() {
        guard var draft = editableAssignmentDraft,
              !draft.inputDigits.isEmpty else {
            return
        }

        draft.inputDigits.removeLast()
        assignmentDraft = draft
    }

    func clearOrCancelAssignmentInput() {
        guard var draft = assignmentDraft,
              !draft.isSubmitting else {
            return
        }

        if draft.inputDigits.isEmpty {
            assignmentDraft = nil
        } else {
            draft.inputDigits = ""
            assignmentDraft = draft
        }
    }

    func setAssignmentInputMode(_ mode: BudgetAssignmentInputMode) {
        guard var draft = editableAssignmentDraft else {
            return
        }

        draft.inputMode = mode
        assignmentDraft = draft
    }

    func assignedAmountDisplay(for category: BudgetMonthCategory) -> BudgetAssignedAmountDisplay {
        guard let draft = assignmentDraft,
              draft.categoryID == category.id else {
            return BudgetAssignedAmountDisplay(
                primaryText: category.budgeted.actualMoney.formatted(),
                secondaryText: nil,
                isEditing: false,
                isDeltaMode: false
            )
        }

        switch draft.inputMode {
        case .direct:
            return BudgetAssignedAmountDisplay(
                primaryText: draft.finalBudgeted.actualMoney.formatted(),
                secondaryText: nil,
                isEditing: true,
                isDeltaMode: false
            )
        case .addition, .subtraction:
            return BudgetAssignedAmountDisplay(
                primaryText: draft.originalBudgeted.actualMoney.formatted(),
                secondaryText: Self.deltaText(
                    for: draft.inputAmount,
                    mode: draft.inputMode
                ),
                isEditing: true,
                isDeltaMode: true
            )
        }
    }

    func isEditingAssignment(for category: BudgetMonthCategory) -> Bool {
        assignmentDraft?.categoryID == category.id
    }

    func submitAssignment(using appState: AppState) async -> Bool {
        guard appState.capabilities.canAssignCategoryBudget else {
            return false
        }

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return false
        }

        return await submitAssignment(budgetID: budgetID, repository: repository)
    }

    func submitAssignment(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard var draft = assignmentDraft,
              let selectedMonth,
              !draft.inputDigits.isEmpty,
              !draft.isSubmitting else {
            return false
        }

        draft.submissionState = .submitting
        assignmentDraft = draft

        do {
            let loadedMonth = try await repository.assignCategoryBudgetAndRefresh(
                categoryID: draft.categoryID,
                budgeted: draft.finalBudgeted,
                budgetID: budgetID,
                month: selectedMonth
            ) { [weak self] in
                await MainActor.run {
                    guard var currentDraft = self?.assignmentDraft,
                          currentDraft.categoryID == draft.categoryID else {
                        return
                    }

                    currentDraft.submissionState = .refetching
                    self?.assignmentDraft = currentDraft
                }
            }
            apply(loadedMonth, preservingExpansion: true)
            assignmentDraft = nil
            return true
        } catch {
            let message = error.localizedDescription
            draft.submissionState = .failed(message)
            assignmentDraft = draft
            return false
        }
    }

    func applyMonthTemplate(
        _ mode: BudgetTemplateApplicationMode,
        using appState: AppState
    ) async -> Bool {
        guard appState.capabilities.canApplyBudgetTemplates else {
            return false
        }

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return false
        }

        let command: BudgetTemplateCommand = mode == .overwrite ? .overwrite : .fillEmpty
        return await applyMonthTemplate(command, budgetID: budgetID, repository: repository)
    }

    func applyMonthTemplate(
        _ command: BudgetTemplateCommand,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard let selectedMonth,
              !monthTemplateSubmissionState.isSubmitting else {
            return false
        }

        monthTemplateSubmissionState = .submitting
        errorMessage = nil

        do {
            let loadedMonth = try await repository.applyBudgetTemplateAndRefresh(
                command: command,
                budgetID: budgetID,
                month: selectedMonth
            ) { [weak self] in
                await MainActor.run {
                    self?.monthTemplateSubmissionState = .refetching
                }
            }
            apply(loadedMonth, preservingExpansion: true)
            monthTemplateSubmissionState = .draft
            errorMessage = nil
            return true
        } catch {
            let message = error.localizedDescription
            monthTemplateSubmissionState = .failed(message)
            errorMessage = message
            return false
        }
    }

    func applyCategoryTemplate(using appState: AppState) async -> Bool {
        guard appState.capabilities.canApplyBudgetTemplates else {
            return false
        }

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return false
        }

        return await applyCategoryTemplate(budgetID: budgetID, repository: repository)
    }

    func applyCategoryTemplate(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard var draft = assignmentDraft,
              let selectedMonth,
              !draft.isSubmitting else {
            return false
        }

        draft.submissionState = .submitting
        assignmentDraft = draft

        do {
            let loadedMonth = try await repository.applyBudgetTemplateAndRefresh(
                command: .category(draft.categoryID),
                budgetID: budgetID,
                month: selectedMonth
            ) { [weak self] in
                await MainActor.run {
                    guard var currentDraft = self?.assignmentDraft,
                          currentDraft.categoryID == draft.categoryID else {
                        return
                    }

                    currentDraft.submissionState = .refetching
                    self?.assignmentDraft = currentDraft
                }
            }
            apply(loadedMonth, preservingExpansion: true)
            assignmentDraft = nil
            errorMessage = nil
            return true
        } catch {
            let message = error.localizedDescription
            draft.submissionState = .failed(message)
            assignmentDraft = draft
            return false
        }
    }

    func submitMoveMoney(using appState: AppState) async -> Bool {
        guard appState.capabilities.canMoveMoney else {
            return false
        }

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return false
        }

        return await submitMoveMoney(budgetID: budgetID, repository: repository)
    }

    func submitMoveMoney(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard var draft = moveMoneyDraft,
              let selectedMonth,
              !draft.isSubmitting else {
            return false
        }

        let commands = moveMoneyCommands(for: draft)
        guard !commands.isEmpty else {
            return false
        }

        draft.submissionState = .submitting
        moveMoneyDraft = draft

        do {
            let loadedMonth = try await repository.moveMoneyAndRefresh(
                commands: commands,
                budgetID: budgetID,
                month: selectedMonth
            ) { [weak self] in
                await MainActor.run {
                    guard var currentDraft = self?.moveMoneyDraft,
                          currentDraft.focusedCategoryID == draft.focusedCategoryID else {
                        return
                    }

                    currentDraft.submissionState = .refetching
                    self?.moveMoneyDraft = currentDraft
                }
            }
            apply(loadedMonth, preservingExpansion: true)
            moveMoneyDraft = nil
            assignmentDraft = nil
            return true
        } catch {
            let message = error.localizedDescription
            draft.submissionState = .failed(message)
            moveMoneyDraft = draft
            return false
        }
    }

    func moveMoneyDestinationGroups(matching searchText: String) -> [BudgetMoveMoneyDestinationGroup] {
        guard let focusedID = moveMoneyDraft?.focusedCategoryID else {
            return []
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleGroups.compactMap { group in
            let options = group.visibleCategories.compactMap { category -> BudgetMoveMoneyDestinationOption? in
                guard category.id != focusedID else {
                    return nil
                }

                let title = category.name.actualistCategoryNameParts.name
                if !trimmedSearch.isEmpty,
                   !title.localizedCaseInsensitiveContains(trimmedSearch),
                   !group.name.localizedCaseInsensitiveContains(trimmedSearch) {
                    return nil
                }

                return BudgetMoveMoneyDestinationOption(
                    id: category.id,
                    title: title,
                    amount: category.balance,
                    valueText: category.balance.actualMoney.formatted(),
                    destination: .category(id: category.id, name: category.name)
                )
            }

            guard !options.isEmpty else {
                return nil
            }

            return BudgetMoveMoneyDestinationGroup(
                id: group.id,
                name: group.name,
                options: options
            )
        }
    }

    func toBudgetDestinationOption() -> BudgetMoveMoneyDestinationOption {
        BudgetMoveMoneyDestinationOption(
            id: "to-budget",
            title: "To Budget",
            amount: budgetMonth?.toBudget ?? 0,
            valueText: (budgetMonth?.toBudget ?? 0).actualMoney.formatted(),
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

    private func apply(_ loadedMonth: LoadedBudgetMonth) {
        apply(loadedMonth, preservingExpansion: false)
    }

    private func apply(
        _ loadedMonth: LoadedBudgetMonth,
        preservingExpansion: Bool
    ) {
        let previousExpandedGroupIDs = expandedGroupIDs
        availableMonths = Self.monthPickerMonths(for: loadedMonth)
        budgetMonth = loadedMonth.month
        selectedMonth = loadedMonth.month.month
        budgetAlerts = loadedMonth.alerts.compactMap(BudgetAlert.init(apiAlert:))
        if preservingExpansion {
            let loadedGroupIDs = Set(loadedMonth.month.categoryGroups.map(\.id))
            expandedGroupIDs = previousExpandedGroupIDs.intersection(loadedGroupIDs)
        } else {
            expandedGroupIDs = Set(loadedMonth.month.categoryGroups.prefix(3).map(\.id))
        }
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

    private var editableAssignmentDraft: BudgetAssignmentDraft? {
        guard let assignmentDraft,
              !assignmentDraft.isSubmitting else {
            return nil
        }

        return assignmentDraft
    }

    private var editableMoveMoneyDraft: BudgetMoveMoneyDraft? {
        guard let moveMoneyDraft,
              !moveMoneyDraft.isSubmitting else {
            return nil
        }

        return moveMoneyDraft
    }

    private func setMoveMoneyAmount(_ amount: Int, draft: inout BudgetMoveMoneyDraft) {
        draft.amount = max(0, amount)
    }

    private func setFocusedMoveMoneyAmount(_ amount: Int, draft: inout BudgetMoveMoneyDraft) {
        let amount = max(0, amount)
        guard !draft.allocations.isEmpty else {
            setMoveMoneyAmount(amount, draft: &draft)
            return
        }

        let focusedID = draft.focusedAllocationID ?? draft.allocations.last?.id
        guard let focusedID,
              let index = draft.allocations.firstIndex(where: { $0.id == focusedID }) else {
            return
        }

        draft.focusedAllocationID = focusedID
        draft.allocations[index].amount = amount
    }

    private func focusedMoveMoneyAmount(in draft: BudgetMoveMoneyDraft) -> Int {
        focusedAllocation(in: draft)?.amount ?? draft.amount
    }

    private func focusedAllocation(in draft: BudgetMoveMoneyDraft) -> BudgetMoveMoneyAllocation? {
        let focusedID = draft.focusedAllocationID ?? draft.allocations.last?.id
        guard let focusedID else {
            return nil
        }

        return draft.allocations.first { $0.id == focusedID }
    }

    private func moveMoneyMaximumAmount(for draft: BudgetMoveMoneyDraft) -> Int {
        let baseline: Int
        switch draft.direction {
        case .outOfFocusedCategory:
            baseline = draft.focusedAvailable
        case .intoFocusedCategory:
            if draft.destination == nil {
                baseline = -min(0, draft.focusedAvailable)
            } else {
                baseline = availableAmount(for: draft.destination)
            }
        }

        return max(100_000, abs(baseline), focusedMoveMoneyAmount(in: draft))
    }

    private func moveMoneyCommand(
        for draft: BudgetMoveMoneyDraft,
        destination: BudgetMoveMoneyDestination
    ) -> BudgetMoveMoneyCommand {
        switch draft.direction {
        case .outOfFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: draft.focusedCategoryID,
                toCategoryID: destination.categoryID,
                amount: draft.amount
            )
        case .intoFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: destination.categoryID,
                toCategoryID: draft.focusedCategoryID,
                amount: draft.amount
            )
        }
    }

    private func moveMoneyCommands(for draft: BudgetMoveMoneyDraft) -> [BudgetMoveMoneyCommand] {
        if !draft.allocations.isEmpty {
            return draft.allocations
                .filter { $0.amount > 0 }
                .map { allocation in
                    moveMoneyCommand(for: draft, destination: allocation.destination, amount: allocation.amount)
                }
        }

        guard let destination = draft.destination, draft.amount > 0 else {
            return []
        }

        return [moveMoneyCommand(for: draft, destination: destination, amount: draft.amount)]
    }

    private func moveMoneyCommand(
        for draft: BudgetMoveMoneyDraft,
        destination: BudgetMoveMoneyDestination,
        amount: Int
    ) -> BudgetMoveMoneyCommand {
        switch draft.direction {
        case .outOfFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: draft.focusedCategoryID,
                toCategoryID: destination.categoryID,
                amount: amount
            )
        case .intoFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: destination.categoryID,
                toCategoryID: draft.focusedCategoryID,
                amount: amount
            )
        }
    }

    private func availableAmount(for destination: BudgetMoveMoneyDestination?) -> Int {
        switch destination {
        case .toBudget:
            budgetMonth?.toBudget ?? 0
        case .category(let id, _):
            category(for: id)?.balance ?? 0
        case nil:
            0
        }
    }

    private func category(for categoryID: String) -> BudgetMonthCategory? {
        visibleGroups
            .flatMap(\.visibleCategories)
            .first { $0.id == categoryID }
    }

    private func makeMoveMoneyDraft(for category: BudgetMonthCategory) -> BudgetMoveMoneyDraft {
        var draft = BudgetMoveMoneyDraft(
            focusedCategoryID: category.id,
            focusedCategoryName: category.name,
            focusedAvailable: category.balance
        )
        if category.balance < 0 {
            draft.direction = .intoFocusedCategory
            draft.amount = -category.balance
        }

        return draft
    }

    private static func deltaText(
        for amount: Int,
        mode: BudgetAssignmentInputMode
    ) -> String {
        let formatted = amount.actualMoney.formatted()
        return mode == .subtraction ? "-\(formatted)" : "+\(formatted)"
    }

    /// Max digits of accumulated cents input (9 → up to $9,999,999.99). Prevents `Int` overflow.
    static let maxAssignmentDigits = 9

    private static func normalizedAssignmentDigits(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        let trimmed = digits.drop(while: { $0 == "0" })
        if trimmed.isEmpty {
            return digits.isEmpty ? "" : "0"
        }

        return String(trimmed)
    }
}

struct BudgetAlert: Identifiable, Equatable {
    enum Kind: String {
        case toBudget
        case overspending
        case uncategorizedTransactions
    }

    enum Severity: Equatable {
        case positive
        case warning
        case danger
    }

    let kind: Kind
    let title: String
    let valueText: String?
    let count: Int?
    let actionTitle: String?
    let severity: Severity

    var id: String {
        kind.rawValue
    }

    init(
        kind: Kind,
        title: String,
        valueText: String? = nil,
        count: Int? = nil,
        actionTitle: String?,
        severity: Severity
    ) {
        self.kind = kind
        self.title = title
        self.valueText = valueText
        self.count = count
        self.actionTitle = actionTitle
        self.severity = severity
    }

    init?(apiAlert: APIBudgetMonthAlert) {
        guard let kind = Kind(rawValue: apiAlert.kind) else {
            return nil
        }

        self.kind = kind
        title = apiAlert.title
        valueText = apiAlert.amount?.actualMoney.formatted()
        count = apiAlert.count
        actionTitle = apiAlert.actionTitle
        severity = Severity(apiValue: apiAlert.severity)
    }
}

private extension BudgetAlert.Severity {
    init(apiValue: String) {
        switch apiValue {
        case "positive":
            self = .positive
        case "danger":
            self = .danger
        default:
            self = .warning
        }
    }
}

extension BudgetMonthCategoryGroup {
    var visibleCategories: [BudgetMonthCategory] {
        categories.filter { !($0.hidden ?? false) }
    }
}
