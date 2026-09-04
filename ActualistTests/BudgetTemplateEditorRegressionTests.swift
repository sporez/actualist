import Foundation
import Testing
@testable import Actualist

@Suite("Template editor plan acceptance")
@MainActor
struct BudgetTemplateEditorRegressionTests {
    private let now = BudgetTemplateCalendar.validatedDate("2026-09-04")!

    @Test(arguments: [BudgetCurrency.usd, .jpy, .none, .catalog(code: "USD", hideFraction: true)])
    func targetAmountUsesLatestVisibleInputAndCurrency(currency: BudgetCurrency) async throws {
        let (vm, repository) = await loaded([.dateTarget(now: now)], currency: currency)
        let id = try #require(vm.editor.items.first?.id)
        #expect(!vm.inputText(for: .amount, id: id).isEmpty)
        vm.edit(.setInput("250.25", field: .amount, id: id))
        #expect(vm.canSave)
        #expect(await vm.save())
        let saved = try #require(await repository.savedDrafts().last?.first)
        guard case .dateTarget(let value) = saved else { Issue.record("Expected date target"); return }
        #expect(value.amount == BudgetTemplateAmountInput.parseAmount("250.25", currency: currency))
        vm.edit(.setInput("", field: .amount, id: id))
        #expect(!vm.canSave)
    }

    @Test func unrelatedControlsPreserveInvalidTextAndSameTypeIsANoop() async throws {
        let (vm, _) = await loaded([.monthlyFixed(amount: 123.45, now: now)])
        let id = try #require(vm.editor.items.first?.id)
        vm.edit(.setInput("12oops", field: .amount, id: id))
        vm.edit(.setFixedCadence(.week, id: id))
        vm.edit(.setKind(.monthlyFixed, id: id))
        #expect(vm.inputText(for: .amount, id: id) == "12oops")
        #expect(!vm.canSave)
        vm.edit(.setInput("250.25", field: .amount, id: id))
        #expect(vm.canSave)
        #expect(await vm.save())
    }

    @Test func togglingDependentFieldsDropsOnlyHiddenInputs() async throws {
        let (vm, _) = await loaded([.dateTarget(now: now)])
        let id = try #require(vm.editor.items.first?.id)
        vm.edit(.setInput("", field: .amount, id: id))
        vm.edit(.setInput("", field: .repeatInterval, id: id))
        vm.edit(.setDateTargetRepeats(false, id: id))
        #expect(vm.editor.inputIsValid(for: .repeatInterval, id: id))
        #expect(!vm.editor.inputIsValid(for: .amount, id: id))
        vm.edit(.setInput("250", field: .amount, id: id))
        #expect(vm.canSave)
    }

    @Test func deletionInvalidatesTotalsAndRowContributionsImmediately() async throws {
        let (vm, _) = await loaded([.monthlyFixed(amount: 100, now: now), .monthlyFixed(amount: 200, now: now)])
        try await waitForPreview(vm)
        #expect(vm.dryRun?.budgeted == 30_000)
        vm.edit(.remove(id: try #require(vm.editor.items.first?.id)))
        #expect(vm.previewState == .loading)
        #expect(vm.dryRun == nil)
        #expect(vm.contributionText(at: 0) == "—")
        try await waitForPreview(vm)
        #expect(vm.dryRun?.perTemplate == [20_000])
    }

    @Test func privacyMasksInputsAndPreservesDefinitionOnOtherEdits() async throws {
        let (vm, repository) = await loaded([.monthlyFixed(amount: 123.45, now: now, description: "Personal note")])
        let id = try #require(vm.editor.items.first?.id)
        vm.isPrivacyModeEnabled = true
        #expect(vm.inputText(for: .amount, id: id) == "Hidden")
        #expect(vm.noteText(id: id).isEmpty)
        #expect(!vm.inputIsEnabled(.amount))
        vm.edit(.setInput("999", field: .amount, id: id))
        vm.edit(.setNoteText("replacement", id: id))
        vm.edit(.setFixedCadence(.week, id: id))
        #expect(await vm.save())
        guard case .monthlyFixed(let value) = await repository.savedDrafts().last?.first else {
            Issue.record("Expected fixed template"); return
        }
        #expect(value.amount == 123.45)
        #expect(value.description == "Personal note")
        vm.isPrivacyModeEnabled = false
        #expect(vm.inputText(for: .amount, id: id) == "123.45")
    }

    @Test func knownInvalidFieldsOpenForCorrectionAcrossFamilies() throws {
        let inputs = [
            #"{"directive":"template","type":"periodic","amount":100,"period":{"period":"month","amount":0},"starting":"2026-02-30","priority":1}"#,
            #"{"directive":"template","type":"limit","amount":-1,"period":"weekly","priority":null}"#,
            #"{"directive":"template","type":"copy","lookBack":-1,"priority":1}"#,
            #"{"directive":"template","type":"average","numMonths":0,"priority":1}"#,
            #"{"directive":"template","type":"by","amount":100,"month":"2027-09","repeat":0,"priority":1}"#,
            #"{"directive":"template","type":"refill","priority":-1}"#
        ]
        for input in inputs {
            let json = "[\(input)]"
            let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
            #expect(BudgetTemplateCategoryLock.evaluate(hasGoalDefColumn: true, hasTemplateSettingsColumn: true,
                source: "ui", noteHasDirectives: false, isStale: false, goalDefJSON: json) == .editable)
            #expect(!BudgetTemplateAuthoringValidation.isValid(drafts, context: .init(today: now)))
        }
    }

    @Test func malformedFixedDateCanBeRepairedWithoutChangingOtherValues() async throws {
        var draft = BudgetTemplateDraft.MonthlyFixed(amount: 123.45, priority: 3, starting: "2026-02-30")
        draft.description = "Keep me"
        let (vm, _) = await loaded([.monthlyFixed(draft)])
        let id = try #require(vm.editor.items.first?.id)
        #expect(vm.editor.fixedStartUsesTextField(for: id))
        #expect(!vm.canSave)
        vm.edit(.setInput("2026-02-28", field: .fixedStart, id: id))
        #expect(vm.canSave)
        guard case .monthlyFixed(let result) = vm.editor.items[0].draft else { return }
        #expect(result.amount == 123.45 && result.priority == 3 && result.description == "Keep me")
    }

    @Test func signedAdjustmentAndUnitChangesPreserveSignAndUnrelatedErrors() async throws {
        let (vm, _) = await loaded([.average(numMonths: 3)])
        let id = try #require(vm.editor.items.first?.id)
        vm.edit(.setAdjustmentMode(.fixed, id: id))
        vm.edit(.setInput("-12.50", field: .adjustment, id: id))
        vm.edit(.setInput("", field: .numMonths, id: id))
        vm.edit(.setAdjustmentMode(.percent, id: id))
        #expect(vm.editor.items[0].draft.modifierAdjustment == .percent(-12.5))
        #expect(vm.inputText(for: .numMonths, id: id).isEmpty)
        #expect(!vm.canSave)
        vm.edit(.setInput("3", field: .numMonths, id: id))
        #expect(vm.canSave)
    }

    @Test func cancellingOrClearingBudgetPreventsSavingAndStalePreviews() async throws {
        let (vm, repository) = await loaded([.monthlyFixed(now: now)])
        vm.cancel()
        #expect(!vm.canSave)
        #expect(await vm.save() == false)
        await vm.load(repository: repository, budgetID: nil)
        #expect(vm.editor.items.isEmpty)
        #expect(vm.errorMessage == "No budget is selected.")
        #expect(!vm.canSave)
    }

    @Test func amountParserRejectsTrailingGarbageAndEditingRetainsHiddenCents() {
        for text in ["12oops", "1.2.3", "1,234", "--1", "+", "-"] {
            #expect(BudgetTemplateAmountInput.parseAmount(text, currency: .usd) == nil)
        }
        #expect(BudgetTemplateAmountInput.formatAmount(123.45, currency: .catalog(code: "USD", hideFraction: true)) == "123.45")
    }

    private func loaded(_ drafts: [BudgetTemplateDraft], currency: BudgetCurrency = .usd) async -> (BudgetTemplateEditorViewModel, EditorTemplateRepository) {
        let snapshot = BudgetTemplateEditorSnapshot(categoryID: "groceries", categoryName: "Groceries", drafts: drafts,
            lock: .editable, schedules: [], currency: currency, hasDefinition: !drafts.isEmpty)
        let repository = EditorTemplateRepository(snapshot: snapshot)
        let vm = BudgetTemplateEditorViewModel(target: .init(categoryID: "groceries", categoryName: "Groceries", month: "2026-09"),
            now: now, dryRunDelay: .milliseconds(30))
        await vm.load(repository: repository, budgetID: "synthetic")
        return (vm, repository)
    }

    private func waitForPreview(_ vm: BudgetTemplateEditorViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while vm.dryRun == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(vm.dryRun != nil)
    }
}
