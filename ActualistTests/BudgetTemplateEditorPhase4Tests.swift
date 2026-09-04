import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor Phase 4")
@MainActor
struct BudgetTemplateEditorPhase4Tests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!
    private let target = BudgetTemplateEditorTarget(
        categoryID: "groceries",
        categoryName: "Groceries",
        month: "2026-09"
    )

    @Test func dateTargetsEncodeRepeatsAndEarlySpendingTransitions() throws {
        let by = BudgetTemplateDraft.dateTarget(
            amount: 1_200,
            month: "2027-09",
            priority: 2,
            repeatInterval: 2,
            annual: true,
            description: "Holiday fund"
        )
        let spend = BudgetTemplateDraft.dateTarget(
            amount: 300,
            month: "2027-09",
            priority: 2,
            repeatInterval: nil,
            annual: false,
            fromMonth: "2027-03",
            isSpend: true
        )

        let encoded = try BudgetTemplateDefinition.encode([by, spend])
        #expect(encoded.contains(#""type":"by""#))
        #expect(encoded.contains(#""type":"spend""#))
        #expect(encoded.contains(#""repeat":2"#))
        #expect(encoded.contains(#""annual":true"#))
        #expect(encoded.contains(#""from":"2027-03""#))
        #expect(BudgetTemplateDefinition.drafts(fromJSON: encoded, now: now) == [by, spend])
    }

    @Test func invalidTargetAndPercentageFieldsRemainRepairable() throws {
        let json = #"""
            [
              {"directive":"template","type":"by","amount":1200,"priority":1},
              {"directive":"template","type":"spend","amount":300,"month":"2026-09","priority":1},
              {"directive":"template","type":"percentage","percent":101,"previous":false,"priority":1}
            ]
            """#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts.count == 3)
        #expect(BudgetTemplateDefinition.isEditorEditableJSON(json, now: now))

        let issues = BudgetTemplateAuthoringValidation.issues(
            for: drafts,
            context: BudgetTemplateAuthoringContext(today: now)
        )
        #expect(issues.contains(.targetMonthMissing(index: 0)))
        #expect(issues.contains(.spendStartMissing(index: 1)))
        #expect(issues.contains(.invalidEntry(index: 2)))
        #expect(issues.contains(.percentageSourceNotFound(index: 2)))
    }

    @Test func missingScheduleReferenceRemainsRepairable() throws {
        let drafts = try #require(BudgetTemplateDefinition.drafts(
            fromJSON: #"[{"directive":"template","type":"schedule","priority":1}]"#,
            now: now
        ))
        #expect(BudgetTemplateDefinition.isEditorEditableJSON(
            #"[{"directive":"template","type":"schedule","priority":1}]"#,
            now: now
        ))
        #expect(BudgetTemplateAuthoringValidation.issues(
            for: drafts,
            context: BudgetTemplateAuthoringContext(today: now)
        ) == [.scheduleNotFound(index: 0)])
    }

    @Test func editorAddsDateTargetsAndAppliesBySpendTransitions() async throws {
        let repository = EditorTemplateRepository(snapshot: snapshot(drafts: []))
        let viewModel = BudgetTemplateEditorViewModel(target: target, now: now, dryRunDelay: .zero)
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(viewModel.editor.addableKinds.contains(.dateTarget))
        viewModel.edit(.add(.dateTarget))
        let id = try #require(viewModel.editor.items.first?.id)
        guard case .dateTarget(let initial) = viewModel.editor.items[0].draft else {
            Issue.record("Expected a date target draft")
            return
        }
        #expect(initial.month == "2027-09")
        #expect(initial.repeatInterval == 1)
        #expect(initial.annual)

        viewModel.edit(.setInput("2027-10", field: .targetMonth, id: id))
        viewModel.edit(.setDateTargetRepeats(false, id: id))
        viewModel.edit(.setDateTargetEarlySpending(true, id: id))
        #expect(viewModel.inputText(for: .spendStartMonth, id: id) == "2027-10")
        viewModel.edit(.setInput("2027-03", field: .spendStartMonth, id: id))
        viewModel.edit(.setDateTargetEarlySpending(false, id: id))
        viewModel.edit(.setDateTargetRepeats(true, id: id))
        viewModel.edit(.setInput("2", field: .repeatInterval, id: id))
        viewModel.edit(.setDateTargetAnnual(false, id: id))

        guard case .dateTarget(let value) = viewModel.editor.items[0].draft else {
            Issue.record("Expected a date target draft after editing")
            return
        }
        #expect(value.month == "2027-10")
        #expect(value.repeatInterval == 2)
        #expect(!value.annual)
        #expect(!value.isSpend)
        #expect(value.fromMonth == nil)
        #expect(viewModel.canSave)
        #expect(await viewModel.save())
        #expect(await repository.savedDrafts() == [[.dateTarget(
            amount: 1_200,
            month: "2027-10",
            priority: 1,
            repeatInterval: 2,
            annual: false
        )]])
    }

    @Test func percentagePickerRepairsMissingSourcesAndAvailableFundsPeriod() async throws {
        let repository = EditorTemplateRepository(snapshot: snapshot(drafts: [
            .percentage(percent: 10, sourceCategory: "Former salary")
        ]))
        let viewModel = BudgetTemplateEditorViewModel(target: target, now: now, dryRunDelay: .zero)
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)

        #expect(viewModel.editor.percentageSourceSelection(for: id) == "Former salary")
        #expect(viewModel.editor.percentageSourceOptions(for: id).first?.isAvailable == false)
        #expect(viewModel.editor.percentageSourceOptions(for: id).contains {
            $0.id == "salary" && $0.name == "Salary"
        })
        #expect(!viewModel.canSave)

        viewModel.edit(.setPercentageSource("salary", id: id))
        #expect(viewModel.canSave)
        viewModel.edit(.setPercentagePrevious(true, id: id))
        #expect(viewModel.editor.items[0].draft == .percentage(
            percent: 10,
            sourceCategory: "salary",
            previous: true
        ))

        viewModel.edit(.setPercentageSource("available funds", id: id))
        #expect(viewModel.editor.items[0].draft.description == nil)
        viewModel.edit(.setPercentagePrevious(false, id: id))
        viewModel.edit(.setPercentageSource("available funds", id: id))
        viewModel.edit(.setPercentagePrevious(true, id: id))
        guard case .percentage(let value) = viewModel.editor.items[0].draft else {
            Issue.record("Expected a percentage draft")
            return
        }
        #expect(value.sourceCategory.isEmpty)
        #expect(!viewModel.canSave)
        viewModel.edit(.setPercentageSource("salary", id: id))
        #expect(viewModel.canSave)
    }

    @Test func hiddenPercentageSourceUsesItsUnavailableCategoryIdentity() async throws {
        let repository = EditorTemplateRepository(snapshot: BudgetTemplateEditorSnapshot(
            categoryID: "groceries",
            categoryName: "Groceries",
            drafts: [.percentage(percent: 10, sourceCategory: "Salary")],
            lock: .editable,
            schedules: [],
            incomeCategories: [
                BudgetTemplateIncomeOption(id: "salary", name: "Salary", isAvailable: false),
                BudgetTemplateIncomeOption(id: "bonus", name: "Bonus")
            ],
            currency: .usd,
            hasDefinition: true
        ))
        let viewModel = BudgetTemplateEditorViewModel(target: target, now: now, dryRunDelay: .zero)
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)

        #expect(viewModel.editor.percentageSourceSelection(for: id) == "salary")
        #expect(viewModel.editor.percentageSourceOptions(for: id).first ==
            BudgetTemplatePercentageSourceOption(
                id: "salary",
                name: "Salary (unavailable)",
                isAvailable: false
            ))
        #expect(viewModel.canSave)
    }

    @Test func percentageConflictsAndInvalidVisibleInputsDisableSave() async throws {
        let repository = EditorTemplateRepository(snapshot: snapshot(drafts: [
            .percentage(percent: 60),
            .percentage(percent: 50, sourceCategory: "ALL INCOME")
        ]))
        let viewModel = BudgetTemplateEditorViewModel(target: target, now: now, dryRunDelay: .zero)
        await viewModel.load(repository: repository, budgetID: "budget-1")
        #expect(viewModel.authoringIssues.contains(.percentageConflict(
            previous: false,
            source: "all income"
        )))
        #expect(!viewModel.canSave)

        let firstID = try #require(viewModel.editor.items.first?.id)
        viewModel.edit(.setInput("101", field: .percent, id: firstID))
        #expect(viewModel.editor.inputIsValid(for: .percent, id: firstID))
        #expect(!viewModel.canSave)
        viewModel.edit(.setInput("15", field: .percent, id: firstID))
        #expect(viewModel.canSave)
        viewModel.edit(.setInput("", field: .percent, id: firstID))
        #expect(!viewModel.editor.inputIsValid(for: .percent, id: firstID))
        #expect(!viewModel.canSave)
    }

    @Test func oneShotPastTargetsRemainEditableButCannotSave() async throws {
        let repository = EditorTemplateRepository(snapshot: snapshot(drafts: [
            .dateTarget(
                month: "2026-08",
                repeatInterval: nil,
                annual: false
            )
        ]))
        let viewModel = BudgetTemplateEditorViewModel(target: target, now: now, dryRunDelay: .zero)
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(viewModel.isEditable)
        #expect(viewModel.authoringIssues.contains(.targetMonthPast(index: 0)))
        #expect(!viewModel.canSave)
        let id = try #require(viewModel.editor.items.first?.id)
        viewModel.edit(.setInput("2026-10", field: .targetMonth, id: id))
        #expect(viewModel.canSave)
    }

    private func snapshot(
        drafts: [BudgetTemplateDraft]
    ) -> BudgetTemplateEditorSnapshot {
        BudgetTemplateEditorSnapshot(
            categoryID: "groceries",
            categoryName: "Groceries",
            drafts: drafts,
            lock: .editable,
            schedules: [],
            incomeCategories: [
                BudgetTemplateIncomeOption(id: "bonus", name: "Bonus"),
                BudgetTemplateIncomeOption(id: "salary", name: "Salary")
            ],
            currency: .usd,
            hasDefinition: !drafts.isEmpty
        )
    }
}
