import Foundation
import Testing
@testable import Actualist

@Suite("Template editor field interactions", .timeLimit(.minutes(2)))
@MainActor
struct BudgetTemplateEditorInteractionTests {
    private let now = BudgetTemplateCalendar.validatedDate("2026-09-04")!

    @Test(arguments: [BudgetCurrency.usd, .jpy, .none, .catalog(code: "USD", hideFraction: true)])
    func moneyFormattingPreservesTypingAndSavedAmounts(currency: BudgetCurrency) async throws {
        let (vm, repository, id) = try await loaded(currency: currency)
        #expect(vm.numericAmount(for: .amount, id: id) == 100)
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        for text in ["", "-", "-1400.2", "-1400.25"] {
            vm.edit(.setInput(text, field: .amount, id: id))
            #expect(vm.inputText(for: .amount, id: id) == text)
            #expect(vm.numericAmount(for: .amount, id: id) == BudgetTemplateAmountInput.numericValue(text))
        }
        #expect(await repository.dryRunCount == 1)
        vm.inputFocusChanged(to: nil)
        let amount = try #require(BudgetTemplateAmountInput.parseAmount("-1400.25", currency: currency))
        #expect(vm.numericAmount(for: .amount, id: id) == Decimal(string: "-1400.25"))
        #expect(vm.inputText(for: .amount, id: id) == "-1400.25")
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        #expect(vm.numericAmount(for: .amount, id: id) == Decimal(string: "-1400.25"))
        #expect(vm.inputText(for: .amount, id: id) == "-1400.25")
        #expect(await vm.save())
        #expect(await repository.savedDrafts().last?.first == .monthlyFixed(amount: amount, now: now))
    }

    @Test func numericProjectionRejectsInvalidInputsAndMasksPrivateAmounts() async throws {
        let (vm, _, id) = try await loaded()
        vm.edit(.setInput("12oops", field: .amount, id: id))
        #expect(vm.numericAmount(for: .amount, id: id) == nil)
        #expect(vm.inputText(for: .amount, id: id) == "12oops")
        #expect(!vm.canSave)
        vm.edit(.setInput("1400.25", field: .amount, id: id))
        #expect(vm.numericAmount(for: .amount, id: id) != nil)
        vm.isPrivacyModeEnabled = true
        #expect(vm.numericAmount(for: .amount, id: id) == nil)
        #expect(vm.inputText(for: .amount, id: id) == "Hidden")
        #expect(vm.numericAmount(for: .priority, id: id) == nil)
        vm.cancel()
    }

    @Test func changingAdjustmentUnitsSwitchesMoneyPresentationOnlyForFixedAmounts() async throws {
        let (vm, _, id) = try await loaded(draft: .average(adjustment: .fixed(-1400.25)))
        #expect(vm.numericAmount(for: .adjustment, id: id) == Decimal(string: "-1400.25"))
        #expect(vm.numericAmount(for: .numMonths, id: id) == nil)
        vm.edit(.setAdjustmentMode(.percent, id: id))
        #expect(!vm.isMoneyInput(.adjustment, id: id))
        #expect(vm.inputText(for: .adjustment, id: id) == "1400.25")
        vm.edit(.setAdjustmentMode(.fixed, id: id))
        #expect(vm.numericAmount(for: .adjustment, id: id) == Decimal(string: "-1400.25"))
        vm.isPrivacyModeEnabled = true
        #expect(vm.numericAmount(for: .adjustment, id: id) == nil)
        #expect(vm.inputText(for: .adjustment, id: id) == "Hidden")
        vm.cancel()
    }

    @Test func contributionBreakdownTracksContributorsInsteadOfModifiersOrAmounts() async throws {
        let (vm, _, firstID) = try await loaded()
        #expect(!vm.showsContributionBreakdown)
        vm.edit(.add(.balanceLimit))
        vm.edit(.add(.goal))
        #expect(vm.editor.items.count == 3)
        #expect(!vm.showsContributionBreakdown)

        vm.edit(.add(.monthlyFixed))
        let secondID = try #require(vm.editor.items.last?.id)
        #expect(vm.showsContributionBreakdown)
        vm.inputFocusChanged(to: .init(itemID: secondID, field: .amount))
        vm.edit(.setInput("", field: .amount, id: secondID))
        #expect(vm.showsContributionBreakdown)
        vm.edit(.setInput("0", field: .amount, id: secondID))
        #expect(vm.showsContributionBreakdown)

        vm.edit(.remove(id: secondID))
        #expect(!vm.showsContributionBreakdown)
        vm.edit(.remove(id: firstID))
        #expect(!vm.showsContributionBreakdown)
        vm.cancel()
    }

    @Test func typingWaitsForFieldCompletionWithoutShowingTransientErrors() async throws {
        let (vm, repository, id) = try await loaded()
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        for text in ["", "-", "2", "25", "250.25"] {
            vm.edit(.setInput(text, field: .amount, id: id))
            #expect(vm.previewState == .editing)
            #expect(vm.dryRun == nil)
            #expect(!vm.inputShowsError(for: .amount, id: id))
            #expect(vm.authoringIssueMessages.isEmpty)
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await repository.dryRunCount == 1)
        vm.inputFocusChanged(to: nil)
        try await waitForTemplatePreview(vm)
        #expect(vm.dryRun?.budgeted == 25_025)
        #expect(await repository.dryRunCount == 2)
    }

    @Test func invalidInputStillBlocksSaveAndShowsErrorOnCompletion() async throws {
        let (vm, repository, id) = try await loaded()
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        vm.edit(.setInput("-", field: .amount, id: id))
        #expect(!vm.canSave)
        #expect(await vm.save() == false)
        #expect(!vm.inputShowsError(for: .amount, id: id))
        vm.inputFocusChanged(to: nil)
        #expect(vm.previewState == .invalid)
        #expect(vm.inputShowsError(for: .amount, id: id))
        #expect(await repository.savedDrafts().isEmpty)
        #expect(await repository.dryRunCount == 1)
    }

    @Test func switchingFieldsFinishesThePreviousFieldAndCancelsItsQueuedPreview() async throws {
        let (vm, repository, id) = try await loaded()
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        vm.edit(.setInput("250", field: .amount, id: id))
        vm.inputFocusChanged(to: .init(itemID: id, field: .interval))
        #expect(vm.previewState == .loading)
        vm.edit(.setInput("", field: .interval, id: id))
        try await Task.sleep(for: .milliseconds(40))
        #expect(vm.previewState == .editing)
        #expect(await repository.dryRunCount == 1)
        vm.inputFocusChanged(to: nil)
        #expect(vm.inputShowsError(for: .interval, id: id))
        #expect(!vm.canSave)
    }

    @Test func authoringIssuesWaitForCompletionButSaveUsesCurrentDraft() async throws {
        let (vm, _, id) = try await loaded(draft: .dateTarget(repeatInterval: nil, now: now))
        vm.inputFocusChanged(to: .init(itemID: id, field: .targetMonth))
        vm.edit(.setInput("2020-01", field: .targetMonth, id: id))
        #expect(!vm.canSave)
        #expect(!vm.authoringIssues.isEmpty)
        #expect(vm.authoringIssueMessages.isEmpty)
        vm.inputFocusChanged(to: nil)
        #expect(!vm.authoringIssueMessages.isEmpty)
        #expect(vm.previewState == .invalid)
    }

    @Test func noteTypingAndClearingLeaveReadyAndPendingPreviewsAlone() async throws {
        let (vm, repository, id) = try await loaded()
        let preview = vm.previewState
        vm.edit(.setNoteText("First line\nSecond line", id: id))
        vm.edit(.clearNote(id: id))
        #expect(vm.previewState == preview)
        #expect(await repository.dryRunCount == 1)
        vm.edit(.setInput("250", field: .amount, id: id))
        vm.edit(.setNoteText("Kept on save", id: id))
        try await waitForTemplatePreview(vm)
        #expect(vm.dryRun?.budgeted == 25_000)
        #expect(await repository.dryRunCount == 2)
        #expect(await vm.save())
        #expect(await repository.savedDrafts().last?.first?.description == "Kept on save")
    }

    @Test func saveWhileFocusedUsesLatestInputAndTeardownCannotRestartPreview() async throws {
        let (vm, repository, id) = try await loaded()
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        vm.edit(.setInput("75", field: .amount, id: id))
        #expect(await vm.save())
        #expect(await repository.savedDrafts().last?.first == .monthlyFixed(amount: 75, now: now))
        #expect(vm.activeInput == nil)
        vm.cancel()
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        vm.inputFocusChanged(to: nil)
        #expect(vm.activeInput == nil)
        #expect(vm.previewState == .idle)
        #expect(await repository.dryRunCount == 1)
    }

    @Test func reloadingClearsFocusAndDiscardsUnfinishedInput() async throws {
        let (vm, repository, id) = try await loaded()
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        vm.edit(.setInput("-", field: .amount, id: id))
        await vm.load(repository: repository, budgetID: "synthetic")
        #expect(vm.activeInput == nil)
        #expect(vm.canSave)
        try await waitForTemplatePreview(vm)
        #expect(vm.dryRun?.budgeted == 10_000)
    }

    @Test func repairedDateKeepsItsTextControlUntilTheEditorReopens() throws {
        let snapshot = BudgetTemplateEditorSnapshot(
            categoryID: "category", categoryName: "Category",
            drafts: [.monthlyFixed(.init(amount: 100, priority: 1, starting: "2026-02-30"))],
            lock: .editable, schedules: [], currency: .usd, hasDefinition: true
        )
        var editor = BudgetTemplateDraftEditor(snapshot: snapshot, now: now)
        let id = try #require(editor.items.first?.id)
        editor.setInput("2026-02-28", field: .fixedStart, id: id)
        #expect(editor.hasValidInputs)
        #expect(editor.fixedStartUsesTextField(for: id))
        editor.setInput("2026-02-2", field: .fixedStart, id: id)
        #expect(!editor.hasValidInputs)
        #expect(editor.fixedStartUsesTextField(for: id))
    }

    private func loaded(draft: BudgetTemplateDraft? = nil, currency: BudgetCurrency = .usd) async throws
        -> (BudgetTemplateEditorViewModel, EditorTemplateRepository, UUID) {
        let repository = EditorTemplateRepository(snapshot: .init(
            categoryID: "category", categoryName: "Category",
            drafts: [draft ?? .monthlyFixed(amount: 100, now: now)],
            lock: .editable, schedules: [], currency: currency, hasDefinition: true
        ))
        let vm = BudgetTemplateEditorViewModel(
            target: .init(categoryID: "category", categoryName: "Category", month: "2026-09"),
            now: now, dryRunDelay: .zero
        )
        await vm.load(repository: repository, budgetID: "synthetic")
        try await waitForTemplatePreview(vm)
        return (vm, repository, try #require(vm.editor.items.first?.id))
    }
}
