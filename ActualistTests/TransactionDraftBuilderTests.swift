import Foundation
import Testing
@testable import Actualist

/// Pure tests for `TransactionDraftBuilder` covering signed amount units,
/// trimmed payee/notes, transfer and category behavior, parent/split flags,
/// real versus preview-only imported-payee values, and invalid drafts.
struct TransactionDraftBuilderTests {
    private static let testDate = Date(timeIntervalSince1970: 1_788_000_000)

    private func baseSubmissionInput(
        accountID: String? = "checking",
        amountCents: Int = 1234,
        kind: TransactionFlowKind = .spend,
        payeeID: String? = nil,
        payeeName: String = "Corner Store",
        notes: String = "",
        cleared: Bool = true,
        categoryID: String? = nil,
        isCategoryReadOnly: Bool = false,
        isSplit: Bool = false,
        isTransfer: Bool = false,
        realImportedPayee: String? = nil,
        reconciled: Bool = false,
        originalIsParent: Bool = false,
        splitDrafts: [TransactionSplitDraft] = []
    ) -> TransactionDraftBuilder.SubmissionInput {
        TransactionDraftBuilder.SubmissionInput(
            accountID: accountID,
            amountCents: amountCents,
            kind: kind,
            payeeID: payeeID,
            payeeName: payeeName,
            notes: notes,
            cleared: cleared,
            categoryID: categoryID,
            isCategoryReadOnly: isCategoryReadOnly,
            isSplit: isSplit,
            isTransfer: isTransfer,
            realImportedPayee: realImportedPayee,
            reconciled: reconciled,
            originalIsParent: originalIsParent,
            date: Self.testDate,
            splitDrafts: splitDrafts
        )
    }

    private func basePreviewInput(
        accountID: String? = "checking",
        amountCents: Int = 1234,
        kind: TransactionFlowKind = .spend,
        payeeID: String? = "employer",
        payeeName: String = "Employer",
        notes: String = "",
        cleared: Bool = true,
        categoryID: String? = "income",
        isCategoryReadOnly: Bool = false,
        isTransfer: Bool = false,
        realImportedPayee: String? = nil,
        reconciled: Bool = false,
        originalIsParent: Bool = false,
        budgetID: String = "budget",
        categorySelection: TransactionEditorCategoryState.Selection = .single(
            TransactionEditorCategoryState.Category(id: "income", name: "Income")
        )
    ) -> TransactionDraftBuilder.RulePreviewInput {
        TransactionDraftBuilder.RulePreviewInput(
            accountID: accountID,
            amountCents: amountCents,
            kind: kind,
            payeeID: payeeID,
            payeeName: payeeName,
            notes: notes,
            cleared: cleared,
            categoryID: categoryID,
            isCategoryReadOnly: isCategoryReadOnly,
            isTransfer: isTransfer,
            realImportedPayee: realImportedPayee,
            reconciled: reconciled,
            originalIsParent: originalIsParent,
            date: Self.testDate,
            budgetID: budgetID,
            categorySelection: categorySelection
        )
    }

    // MARK: - signed amount units

    @Test func spendKindSignsAmountNegative() throws {
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(kind: .spend)))
        #expect(draft.amountMinorUnits == -1234)
    }

    @Test func inflowKindSignsAmountPositive() throws {
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(kind: .inflow)))
        #expect(draft.amountMinorUnits == 1234)
    }

    // MARK: - trimmed payee/notes

    @Test func submitDraftTrimsPayeeAndNotesAndNilsBlankNotes() throws {
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(
            payeeName: "  Corner Store  ",
            notes: "  weekly groceries  "
        )))
        #expect(draft.payeeName == "Corner Store")
        #expect(draft.notes == "weekly groceries")
    }

    @Test func submitDraftNilsNotesWhenBlank() throws {
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(notes: "   ")))
        #expect(draft.notes == nil)
    }

    // MARK: - transfer and category behavior

    @Test func transferDraftClearsSplitsAndKeepsProvidedCategory() throws {
        let split = TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1234)
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(
            categoryID: "groceries",
            isTransfer: true,
            splitDrafts: [split]
        )))
        #expect(draft.isTransfer)
        // Transfers empty split drafts even when a split was supplied.
        #expect(draft.splits == [])
        // The builder does not nil the category for a transfer unless read-only.
        #expect(draft.categoryID == "groceries")
    }

    @Test func readOnlyCategoryDraftNilsCategoryAndEmptiesSplits() throws {
        let split = TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1234)
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(
            categoryID: "groceries",
            isCategoryReadOnly: true,
            splitDrafts: [split]
        )))
        #expect(draft.categoryID == nil)
        #expect(draft.splits == [])
    }

    @Test func splitDraftNilsCategoryAndSetsParentFlagWithSignedSplits() throws {
        let splits = [
            TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -500),
            TransactionSplitDraft(id: nil, categoryID: "household", categoryName: "Household", amountMinorUnits: -734)
        ]
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(
            isSplit: true,
            splitDrafts: splits
        )))
        #expect(draft.categoryID == nil)
        #expect(draft.isParent)
        #expect(draft.splits.map(\.categoryID) == ["groceries", "household"])
        // The builder preserves the pre-signed split amounts from the input.
        #expect(draft.splits.map(\.amountMinorUnits) == [-500, -734])
    }

    @Test func splitDraftIsParentSetWhenOriginalWasParentEvenWhenNotSplit() throws {
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(
            originalIsParent: true
        )))
        #expect(draft.isParent)
    }

    // MARK: - real versus preview-only imported-payee

    @Test func submitDraftKeepsRealImportedPayeeAndDoesNotSynthesizeOne() throws {
        // Manual entry: real imported payee is nil; the saved draft must keep nil
        // even though the preview would synthesize the entered payee name.
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(
            payeeName: "1Password",
            realImportedPayee: nil
        )))
        #expect(draft.importedPayee == nil)
    }

    @Test func submitDraftKeepsRealImportedPayeeWhenEditingImportedTransaction() throws {
        let draft = try #require(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(
            realImportedPayee: "1PASSWORD*SUBSCRIPTION"
        )))
        #expect(draft.importedPayee == "1PASSWORD*SUBSCRIPTION")
    }

    @Test func previewRequestSynthesizesImportedPayeeFromPayeeNameForManualEntry() throws {
        let request = try #require(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(
            payeeID: nil,
            payeeName: "1Password",
            realImportedPayee: nil
        )))
        #expect(request.draft.payeeName == "1Password")
        #expect(request.draft.importedPayee == "1Password")
    }

    @Test func previewRequestKeepsRealImportedPayeeWhenEditingImportedTransaction() throws {
        let request = try #require(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(
            realImportedPayee: "1PASSWORD*SUBSCRIPTION"
        )))
        #expect(request.draft.importedPayee == "1PASSWORD*SUBSCRIPTION")
    }

    @Test func previewRequestCarriesCategorySelection() throws {
        let selection: TransactionEditorCategoryState.Selection = .single(
            TransactionEditorCategoryState.Category(id: "income", name: "Income")
        )
        let request = try #require(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(categorySelection: selection)))
        #expect(request.categorySelection == selection)
    }

    @Test func previewDraftHasNoSplitsAndMirrorsOriginalParentFlag() throws {
        let request = try #require(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(
            payeeID: nil,
            payeeName: "Target",
            originalIsParent: true
        )))
        // Preview drafts never carry splits and mirror the original isParent.
        #expect(request.draft.splits == [])
        #expect(request.draft.isParent)
    }

    @Test func previewRequestNilsCategoryWhenReadOnly() throws {
        let request = try #require(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(
            categoryID: "groceries",
            isCategoryReadOnly: true
        )))
        #expect(request.draft.categoryID == nil)
    }

    @Test func previewRequestClampsZeroAmountToZeroForMatching() throws {
        let request = try #require(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(amountCents: 0)))
        #expect(request.draft.amountMinorUnits == 0)
    }

    // MARK: - invalid drafts

    @Test func submitDraftRejectsMissingAccount() {
        #expect(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(accountID: nil)) == nil)
    }

    @Test func submitDraftRejectsZeroAmount() {
        #expect(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(amountCents: 0)) == nil)
    }

    @Test func submitDraftRejectsBlankPayee() {
        #expect(TransactionDraftBuilder.makeSubmissionDraft(from: baseSubmissionInput(payeeName: "   ")) == nil)
    }

    @Test func previewRequestRejectsMissingAccount() {
        #expect(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(accountID: nil)) == nil)
    }

    @Test func previewRequestRejectsBlankPayee() {
        #expect(TransactionDraftBuilder.makeRulePreviewRequest(from: basePreviewInput(payeeName: "  ")) == nil)
    }
}
