import Foundation

/// Pure builder for transaction editor drafts.
///
/// Receives an immutable snapshot of the authoritative editor/category state at
/// intent time and decides signed amount units, trimmed payee/notes, transfer
/// and category behavior, parent/split flags, real versus preview-only
/// imported-payee values, and split drafts. It holds no state and performs no
/// repository or AppState access; the editor view model snapshots its fields
/// into a `SubmissionInput`/`RulePreviewInput` and passes it here.
enum TransactionDraftBuilder {
    /// Snapshot used to build the saved create/update draft.
    struct SubmissionInput: Sendable {
        let accountID: String?
        let amountCents: Int
        let kind: TransactionFlowKind
        let payeeID: String?
        let payeeName: String
        let notes: String
        let cleared: Bool
        let categoryID: String?
        let isCategoryReadOnly: Bool
        let isSplit: Bool
        let isTransfer: Bool
        let realImportedPayee: String?
        let reconciled: Bool
        let originalIsParent: Bool
        let date: Date
        /// Pre-signed split drafts from `TransactionEditorCategoryState.splitDrafts(sign:)`.
        /// Emptied by the builder when the submission is a transfer or the
        /// category is read-only, matching the prior in-line behavior.
        let splitDrafts: [TransactionSplitDraft]
    }

    /// Snapshot used to build a rule-preview request.
    struct RulePreviewInput: Sendable {
        let accountID: String?
        let amountCents: Int
        let kind: TransactionFlowKind
        let payeeID: String?
        let payeeName: String
        let notes: String
        let cleared: Bool
        let categoryID: String?
        let isCategoryReadOnly: Bool
        let isTransfer: Bool
        let realImportedPayee: String?
        let reconciled: Bool
        let originalIsParent: Bool
        let date: Date
        let budgetID: String
        let categorySelection: TransactionEditorCategoryState.Selection
    }

    /// Builds the saved create/update draft. Returns nil when the account is
    /// missing, the amount is non-positive, or the payee is blank — matching
    /// the editor's `canSave` precondition so an invalid draft never reaches
    /// the repository.
    static func makeSubmissionDraft(from input: SubmissionInput) -> TransactionDraft? {
        guard let accountID = input.accountID else {
            return nil
        }

        let trimmedPayee = input.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.amountCents > 0, !trimmedPayee.isEmpty else {
            return nil
        }

        let signedAmount = input.kind == .spend ? -input.amountCents : input.amountCents
        let trimmedNotes = input.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let submitsNoCategory = input.isCategoryReadOnly || input.isSplit
        let splits = input.isTransfer || input.isCategoryReadOnly ? [] : input.splitDrafts

        return TransactionDraft(
            accountID: accountID,
            date: input.date,
            amountMinorUnits: signedAmount,
            payeeID: input.payeeID,
            payeeName: trimmedPayee,
            categoryID: submitsNoCategory ? nil : input.categoryID,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            cleared: input.cleared,
            isTransfer: input.isTransfer,
            importedPayee: input.realImportedPayee,
            reconciled: input.reconciled,
            isParent: input.isSplit || input.originalIsParent,
            splits: splits
        )
    }

    /// Builds the rule-preview request. The preview draft never carries splits
    /// and mirrors the original `isParent` (the editor gates previews on
    /// `!isSplit`). Manually-added transactions feed the entered payee name as
    /// the imported-payee text for rule matching; the saved draft keeps its
    /// real (nil) imported payee.
    static func makeRulePreviewRequest(from input: RulePreviewInput) -> TransactionRulePreviewRequest? {
        guard let accountID = input.accountID else {
            return nil
        }

        let trimmedPayee = input.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayee.isEmpty else {
            return nil
        }

        let signedAmount: Int
        if input.amountCents > 0 {
            signedAmount = input.kind == .spend ? -input.amountCents : input.amountCents
        } else {
            signedAmount = 0
        }

        let trimmedNotes = input.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let rulePreviewImportedPayee = input.realImportedPayee ?? trimmedPayee

        return TransactionRulePreviewRequest(
            budgetID: input.budgetID,
            draft: TransactionDraft(
                accountID: accountID,
                date: input.date,
                amountMinorUnits: signedAmount,
                payeeID: input.payeeID,
                payeeName: trimmedPayee,
                categoryID: input.isCategoryReadOnly ? nil : input.categoryID,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                cleared: input.cleared,
                isTransfer: input.isTransfer,
                importedPayee: rulePreviewImportedPayee,
                reconciled: input.reconciled,
                isParent: input.originalIsParent
            ),
            categorySelection: input.categorySelection
        )
    }
}
