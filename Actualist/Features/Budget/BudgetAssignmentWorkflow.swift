import Foundation
import Observation

@MainActor
@Observable
final class BudgetAssignmentWorkflow {
    nonisolated static let maxInputDigits = 9

    struct Context: Equatable {
        let id = UUID()
        let budgetID: String
        let categoryID: String
        let month: String
        let modeIdentity: BudgetModeIdentity?
    }

    private(set) var completionRevision = 0
    private var capturedContext: Context?
    var context: Context? { draft == nil ? nil : capturedContext }

    /// Invalidating detaches an old command; it cannot cancel a committed write.
    func invalidate() {
        capturedContext = nil
        draft = nil
    }

    func reconcile(budgetID: String, month: String? = nil, categoryIDs: Set<String>? = nil) {
        guard let context else { return }
        if context.budgetID != budgetID || categoryIDs?.contains(context.categoryID) == false {
            invalidate()
        } else if let month, context.month != month {
            invalidate()
        }
    }

    private(set) var draft: BudgetAssignmentDraft?

    var isPresented: Bool {
        draft != nil
    }

    var activeCategoryID: String? {
        draft?.categoryID
    }

    var canSubmit: Bool {
        guard let draft else {
            return false
        }

        return !draft.inputDigits.isEmpty && !draft.isSubmitting
    }

    var errorMessage: String? {
        guard let draft,
              case .failed(let message) = draft.submissionState else {
            return nil
        }

        return message
    }

    var isSubmitting: Bool {
        draft?.isSubmitting == true
    }

    var canApplyCategoryTemplate: Bool {
        guard let draft else {
            return false
        }

        return !draft.isSubmitting
    }

    func begin(
        for category: BudgetMonthCategory,
        budgetID: String?,
        month: String?,
        modeIdentity: BudgetModeIdentity? = nil
    ) {
        guard draft?.isSubmitting != true else {
            return
        }

        capturedContext = budgetID.flatMap { budget in
            month.map {
                Context(
                    budgetID: budget,
                    categoryID: category.id,
                    month: $0,
                    modeIdentity: modeIdentity
                )
            }
        }
        draft = BudgetAssignmentDraft(
            categoryID: category.id,
            originalBudgeted: category.budgeted,
            inputDigits: "",
            inputMode: .direct
        )
    }

    func cancel() {
        guard draft?.isSubmitting != true else {
            return
        }

        draft = nil
    }

    func resetAfterRelatedWorkflow() {
        draft = nil
    }

    func appendDigit(_ digit: Int) {
        guard var draft = editableDraft,
              (0...9).contains(digit) else {
            return
        }

        let candidate = Self.normalizedDigits(draft.inputDigits + String(digit))
        guard candidate.count <= Self.maxInputDigits else {
            return
        }

        draft.inputDigits = candidate
        self.draft = draft
    }

    func deleteDigit() {
        guard var draft = editableDraft,
              !draft.inputDigits.isEmpty else {
            return
        }

        draft.inputDigits.removeLast()
        self.draft = draft
    }

    /// Replaces only the typed operand. Calculation and overflow validation
    /// remain owned by `BudgetAssignmentDraft`.
    func replaceInputDigits(_ digits: String) {
        guard var draft = editableDraft,
              digits.allSatisfy(\.isNumber),
              digits.count <= Self.maxInputDigits else { return }
        draft.inputDigits = digits
        self.draft = draft
    }

    func clearInputOrCancel() {
        guard var draft,
              !draft.isSubmitting else {
            return
        }

        if draft.inputDigits.isEmpty {
            self.draft = nil
        } else {
            draft.inputDigits = ""
            self.draft = draft
        }
    }

    func setInputMode(_ mode: BudgetAssignmentInputMode) {
        guard var draft = editableDraft else {
            return
        }

        draft.inputMode = mode
        self.draft = draft
    }

    func amountDisplay(
        for category: BudgetMonthCategory,
        currency: BudgetCurrency,
        randomized: Bool = false
    ) -> BudgetAssignedAmountDisplay {
        guard let draft,
              draft.categoryID == category.id else {
            return BudgetAssignedAmountDisplay(
                primaryText: currency.formatted(category.budgeted),
                secondaryText: nil,
                isEditing: false,
                isDeltaMode: false
            )
        }

        let displayDraft = randomized ? BudgetAssignmentDraft(
            categoryID: draft.categoryID, originalBudgeted: category.budgeted,
            inputDigits: draft.inputDigits, inputMode: draft.inputMode
        ) : draft
        switch displayDraft.inputMode {
        case .direct:
            return BudgetAssignedAmountDisplay(
                primaryText: currency.formatted(displayDraft.finalBudgeted),
                secondaryText: nil,
                isEditing: true,
                isDeltaMode: false
            )
        case .addition, .subtraction:
            return BudgetAssignedAmountDisplay(
                primaryText: currency.formatted(displayDraft.originalBudgeted),
                secondaryText: Self.deltaText(
                    for: draft.inputAmount,
                    mode: draft.inputMode,
                    currency: currency
                ),
                isEditing: true,
                isDeltaMode: true
            )
        }
    }

    func isEditing(_ category: BudgetMonthCategory) -> Bool {
        draft?.categoryID == category.id
    }

    func submit(
        selectedMonth: String,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard let context, context.budgetID == budgetID, context.month == selectedMonth,
              var draft,
              !draft.inputDigits.isEmpty,
              !draft.isSubmitting else {
            return nil
        }

        guard let finalBudgeted = draft.validatedFinalBudgeted else {
            draft.submissionState = .failed("The assigned amount is too large.")
            self.draft = draft
            return nil
        }

        draft.submissionState = .submitting
        self.draft = draft

        do {
            let loadedMonth = try await repository.assignCategoryBudgetAndRefresh(expectedMode: context.modeIdentity,
                categoryID: draft.categoryID,
                budgeted: finalBudgeted,
                budgetID: context.budgetID,
                month: context.month
            ) { [weak self] in
                await MainActor.run {
                    guard var currentDraft = self?.draft,
                          self?.context == context else {
                        return
                    }

                    currentDraft.submissionState = .refetching
                    self?.draft = currentDraft
                }
            }
            completionRevision += 1
            guard self.context == context else { return nil }
            guard loadedMonth.modeIdentity == context.modeIdentity else {
                invalidate()
                return nil
            }
            self.draft = nil
            return loadedMonth
        } catch {
            guard self.context == context else { return nil }
            if case BudgetModeWriteError.budgetChanged = error {
                invalidate()
                return nil
            }
            draft.submissionState = error.userFacingMessage.map(BudgetAssignmentSubmissionState.failed) ?? .draft
            self.draft = draft
            return nil
        }
    }

    func applyCategoryTemplate(
        selectedMonth: String,
        budgetID: String,
        expectedMode: BudgetModeIdentity? = nil,
        reviewRevision: BudgetTemplateReviewRevision? = nil,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard let context, context.budgetID == budgetID, context.month == selectedMonth,
              var draft,
              !draft.isSubmitting else {
            return nil
        }

        draft.submissionState = .submitting
        self.draft = draft

        do {
            let didApply: @MainActor @Sendable () async -> Void = { [weak self] in
                await MainActor.run {
                    guard var currentDraft = self?.draft,
                          self?.context == context else {
                        return
                    }

                    currentDraft.submissionState = .refetching
                    self?.draft = currentDraft
                }
            }
            let command = BudgetTemplateCommand.category(draft.categoryID)
            let loadedMonth: LoadedBudgetMonth
            if let reviewRevision {
                loadedMonth = try await repository.applyReviewedBudgetTemplateAndRefresh(
                    reviewRevision: reviewRevision,
                    command: command,
                    budgetID: context.budgetID,
                    month: context.month,
                    didApply: didApply
                )
            } else {
                loadedMonth = try await repository.applyBudgetTemplateAndRefresh(
                    expectedMode: expectedMode ?? context.modeIdentity,
                    command: command,
                    budgetID: context.budgetID,
                    month: context.month,
                    didApply: didApply
                )
            }
            completionRevision += 1
            guard self.context == context else { return nil }
            guard loadedMonth.modeIdentity == context.modeIdentity else {
                invalidate()
                return nil
            }
            self.draft = nil
            return loadedMonth
        } catch {
            guard self.context == context else { return nil }
            if case BudgetModeWriteError.budgetChanged = error {
                invalidate()
                return nil
            }
            draft.submissionState = error.userFacingMessage.map(BudgetAssignmentSubmissionState.failed) ?? .draft
            self.draft = draft
            return nil
        }
    }

    private var editableDraft: BudgetAssignmentDraft? {
        guard let draft,
              !draft.isSubmitting else {
            return nil
        }

        return draft
    }

    private static func normalizedDigits(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        let trimmed = digits.drop(while: { $0 == "0" })
        if trimmed.isEmpty {
            return digits.isEmpty ? "" : "0"
        }

        return String(trimmed)
    }

    private static func deltaText(
        for amount: Int,
        mode: BudgetAssignmentInputMode,
        currency: BudgetCurrency
    ) -> String {
        let formatted = currency.formatted(amount)
        return mode == .subtraction ? "-\(formatted)" : "+\(formatted)"
    }
}
