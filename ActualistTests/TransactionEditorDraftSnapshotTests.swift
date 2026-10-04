import Foundation
import Testing
@testable import Actualist

/// Unsaved-change detection behind the editor's swipe-to-dismiss guard and
/// discard confirmation: nothing is unsaved before load, load-time defaults
/// form the baseline, and only the user's own edits count.
@MainActor
struct TransactionEditorDraftSnapshotTests {
    private func loadedNewModel() -> TransactionEditorViewModel {
        let model = TransactionEditorViewModel()
        model.selectedAccountID = "checking"
        model.date = TransactionEditorViewModelTests.date("2026-06-14")
        model.captureDraftBaselineIfNeeded()
        return model
    }

    @Test func nothingIsUnsavedBeforeTheEditorLoads() {
        let model = TransactionEditorViewModel()
        model.amountDigits = "1234"

        #expect(!model.hasUnsavedChanges)
    }

    @Test func loadTimeDefaultsAreNotUnsaved() {
        #expect(!loadedNewModel().hasUnsavedChanges)
    }

    @Test func eachEditableFieldCountsAsUnsaved() {
        let edits: [(TransactionEditorViewModel) -> Void] = [
            { $0.amountDigits = "1" },
            { $0.kind = .inflow },
            { $0.payeeName = "Corner Store" },
            { $0.selectedPayeeID = "payee-1" },
            { $0.selectedAccountID = "savings" },
            { $0.notes = "lunch" },
            { $0.isCleared.toggle() },
            { $0.date = TransactionEditorViewModelTests.date("2026-06-15") },
            { $0.beginSplit() },
        ]
        for edit in edits {
            let model = loadedNewModel()
            edit(model)
            #expect(model.hasUnsavedChanges)
        }
    }

    @Test func revertingAnEditClearsUnsavedChanges() {
        let model = loadedNewModel()
        model.amountDigits = "12"
        #expect(model.hasUnsavedChanges)

        model.amountDigits = ""
        #expect(!model.hasUnsavedChanges)
    }

    @Test func sameDayTimeChangeIsNotUnsaved() {
        let model = loadedNewModel()
        model.date = model.date.addingTimeInterval(60 * 60)

        #expect(!model.hasUnsavedChanges)
    }

    @Test func clearedToggleIsNotUnsavedWhenEditingBecauseItCommitsImmediately() {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-1",
                account: "checking",
                date: "2026-06-13",
                amount: -1200,
                payee: nil,
                payeeName: nil,
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: .bool(false)
            )
        )
        model.captureDraftBaselineIfNeeded()
        model.isCleared = true
        #expect(!model.hasUnsavedChanges)

        model.notes = "edited"
        #expect(model.hasUnsavedChanges)
    }

    @Test func laterLoadsKeepTheOriginalBaseline() {
        let model = loadedNewModel()
        model.amountDigits = "500"
        model.captureDraftBaselineIfNeeded()

        #expect(model.hasUnsavedChanges)
    }
}
