import Foundation
import Observation

enum BudgetAssignmentInputMode: Equatable {
    case direct
    case addition
    case subtraction
}

enum BudgetAssignmentSubmissionState: Equatable {
    case draft
    case submitting
    case refetching
    case failed(String)
}

struct BudgetAssignmentDraft: Equatable {
    let categoryID: String
    let originalBudgeted: Int
    var inputDigits: String
    var inputMode: BudgetAssignmentInputMode
    var submissionState: BudgetAssignmentSubmissionState = .draft

    var isSubmitting: Bool {
        switch submissionState {
        case .submitting, .refetching:
            true
        case .draft, .failed:
            false
        }
    }

    var inputAmount: Int {
        Int(inputDigits) ?? 0
    }

    var finalBudgeted: Int {
        switch inputMode {
        case .direct:
            inputDigits.isEmpty ? originalBudgeted : inputAmount
        case .addition:
            originalBudgeted + inputAmount
        case .subtraction:
            originalBudgeted - inputAmount
        }
    }

    var signedDelta: Int {
        switch inputMode {
        case .direct:
            0
        case .addition:
            inputAmount
        case .subtraction:
            -inputAmount
        }
    }
}

struct BudgetAssignedAmountDisplay: Equatable {
    let primaryText: String
    let secondaryText: String?
    let isEditing: Bool
    let isDeltaMode: Bool
}

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

    var navigationTitle: String {
        guard let selectedMonth else {
            return Self.title(for: Date())
        }

        return Self.title(forMonthIdentifier: selectedMonth)
    }

    var visibleGroups: [BudgetMonthCategoryGroup] {
        budgetMonth?.categoryGroups.filter { !$0.isIncome } ?? []
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

    func load(using appState: AppState) async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return
        }

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
        availableMonths = loadedMonth.availableMonths
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

    private var editableAssignmentDraft: BudgetAssignmentDraft? {
        guard let assignmentDraft,
              !assignmentDraft.isSubmitting else {
            return nil
        }

        return assignmentDraft
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
