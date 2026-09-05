import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor view model", .timeLimit(.minutes(2)))
@MainActor
struct BudgetTemplateEditorViewModelTests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!
    private let target = BudgetTemplateEditorTarget(
        categoryID: "groceries",
        categoryName: "Groceries",
        month: "2026-09"
    )

    @Test func loadEditableDraftsAndSaveWithoutApplying() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(viewModel.phase == .ready)
        #expect(viewModel.isEditable)
        #expect(viewModel.canSave)
        #expect(viewModel.navigationTitle == "Edit Templates")
        #expect(viewModel.editor.items.map(\.draft) == [.monthlyFixed(amount: 400, now: now)])

        viewModel.edit(.setInput("250", field: .amount, id: try #require(viewModel.editor.items.first?.id)))
        let saved = await viewModel.save()
        #expect(saved)
        let drafts = await repository.savedDrafts()
        #expect(drafts == [[.monthlyFixed(amount: 250, now: now)]])
    }

    @Test func readOnlyRefusesMutationsAndSave() async throws {
        let repository = EditorTemplateRepository(
            snapshot: BudgetTemplateEditorSnapshot(
                categoryID: "groceries",
                categoryName: "Groceries",
                drafts: [.monthlyFixed(amount: 400, now: now)],
                lock: .readOnly(.noteManaged),
                schedules: [],
                currency: .usd,
                hasDefinition: true
            )
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(!viewModel.isEditable)
        #expect(!viewModel.canSave)
        #expect(viewModel.navigationTitle == "View Templates")
        viewModel.edit(.add(.remainder))
        #expect(viewModel.editor.items.count == 1)
        #expect(await viewModel.save() == false)
        #expect(await repository.savedDrafts().isEmpty)
    }

    @Test func addRemoveAndSingletonKinds() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(viewModel.navigationTitle == "Add Template")
        viewModel.edit(.add(.monthlyFixed))
        viewModel.edit(.add(.remainder))
        viewModel.edit(.add(.remainder))
        #expect(viewModel.editor.items.map(\.draft.kind) == [.monthlyFixed, .remainder])
        #expect(!viewModel.editor.addableKinds.contains(.remainder))
        viewModel.edit(.remove(id: try #require(viewModel.editor.items.last?.id)))
        #expect(viewModel.editor.items.map(\.draft.kind) == [.monthlyFixed])
        #expect(viewModel.editor.addableKinds.contains(.remainder))
    }

    @Test func incompleteScheduleCannotSave() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        viewModel.edit(.add(.schedule))
        #expect(!viewModel.canSave)
        viewModel.edit(.setSchedule(
            "rent",
            id: try #require(viewModel.editor.items.first?.id)
        ))
        #expect(viewModel.canSave)
    }

    @Test func dryRunFollowsCurrentDrafts() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        try await waitForTemplatePreview(viewModel)
        #expect(viewModel.dryRun?.budgeted == 40_000)
        #expect(viewModel.dryRun?.perTemplate == [40_000])

        viewModel.edit(.setInput("100", field: .amount, id: try #require(viewModel.editor.items.first?.id)))
        try await waitForTemplatePreview(viewModel)
        #expect(viewModel.dryRun?.budgeted == 10_000)
        #expect(viewModel.dryRun?.perTemplate == [10_000])
    }

    @Test func invalidVisibleInputDisablesSaveUntilCorrected() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)
        try await waitForTemplatePreview(viewModel)
        #expect(viewModel.dryRun?.budgeted == 40_000)

        viewModel.edit(.setInput("", field: .amount, id: id))
        #expect(viewModel.inputText(for: .amount, id: id).isEmpty)
        #expect(!viewModel.editor.inputIsValid(for: .amount, id: id))
        #expect(!viewModel.canSave)
        #expect(viewModel.dryRun == nil)

        viewModel.edit(.setInput("250", field: .amount, id: id))
        #expect(viewModel.editor.inputIsValid(for: .amount, id: id))
        #expect(viewModel.canSave)
        try await waitForTemplatePreview(viewModel)
        #expect(viewModel.dryRun?.budgeted == 25_000)
    }

    @Test func notesAreIndependentAndClearWithoutChangingTheTemplateMath() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [
                .monthlyFixed(amount: 400, now: now),
                .copy(lookBack: 2)
            ])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let firstID = try #require(viewModel.editor.items.first?.id)
        let secondID = try #require(viewModel.editor.items.last?.id)

        let firstNote = "First line\nSecond line"
        viewModel.edit(.setNoteText(firstNote, id: firstID))
        viewModel.edit(.setNoteText("Copy this month's history", id: secondID))
        #expect(viewModel.noteText(id: firstID) == firstNote)
        #expect(viewModel.editor.hasNote(id: firstID))
        #expect(viewModel.noteText(id: secondID) == "Copy this month's history")
        try await waitForTemplatePreview(viewModel)
        #expect(viewModel.dryRun?.budgeted == 40_000)
        #expect(await viewModel.save())

        let saved = try #require(await repository.savedDrafts().last)
        #expect(saved.map(\.description) == [firstNote, "Copy this month's history"])

        viewModel.edit(.clearNote(id: firstID))
        #expect(viewModel.noteText(id: firstID).isEmpty)
        #expect(!viewModel.editor.hasNote(id: firstID))
        #expect(viewModel.noteText(id: secondID) == "Copy this month's history")
        #expect(await viewModel.save())
        let cleared = try #require(await repository.savedDrafts().last)
        #expect(cleared.map(\.description) == [nil, "Copy this month's history"])
    }

    @Test func typeChangesPreserveIdentityAndNotesWithPinnedDefaults() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [
                .monthlyFixed(amount: 400, priority: 3, now: now, description: "Keep this note")
            ])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)

        viewModel.edit(.setKind(.copy, id: id))
        #expect(viewModel.editor.items.first?.id == id)
        guard case .copy(let copy) = viewModel.editor.items.first?.draft else {
            Issue.record("Expected the item to become Copy")
            return
        }
        #expect(copy.priority == 1)
        #expect(copy.description == "Keep this note")
        #expect(viewModel.canSave)
    }

    @Test func typeChangeRespectsSingletonKindsAlreadyInTheList() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(now: now), .remainder()])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let fixedID = try #require(viewModel.editor.items.first?.id)

        #expect(!viewModel.editor.typeChangeKinds(for: fixedID).contains(.remainder))
        viewModel.edit(.setKind(.remainder, id: fixedID))
        #expect(viewModel.editor.items.first?.draft.kind == .monthlyFixed)
    }

    @Test func copyAndAverageTypeChangesRetainTheHistoryCountAndPriority() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [
                .average(
                    numMonths: 5,
                    priority: 3,
                    adjustment: .percent(10)
                )
            ])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)

        viewModel.edit(.setKind(.copy, id: id))
        guard case .copy(let copy) = viewModel.editor.items.first?.draft else {
            Issue.record("Expected the item to become Copy")
            return
        }
        #expect(copy.lookBack == 5)
        #expect(copy.priority == 3)
        viewModel.edit(.setKind(.average, id: id))
        guard case .average(let average) = viewModel.editor.items.first?.draft else {
            Issue.record("Expected the item to become Average")
            return
        }
        #expect(average.numMonths == 5)
        #expect(average.priority == 3)
        #expect(average.adjustment == nil)
    }

    @Test func phase5ModifierControlsRetainSignedValuesAndSave() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [
                .average(numMonths: 5, priority: 3),
                .schedule(name: "Rent", scheduleId: "rent", priority: 3)
            ])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let averageID = try #require(viewModel.editor.items.first?.id)
        let scheduleID = try #require(viewModel.editor.items.last?.id)

        viewModel.edit(.setAdjustmentMode(.percent, id: averageID))
        #expect(viewModel.editor.items.first?.draft == .average(
            numMonths: 5,
            priority: 3,
            adjustment: .percent(10)
        ))
        viewModel.edit(.setAdjustmentMode(.none, id: averageID))
        #expect(viewModel.editor.adjustmentMode(for: averageID) == .none)
        viewModel.edit(.setAdjustmentMode(.fixed, id: averageID))
        #expect(viewModel.editor.adjustmentMode(for: averageID) == .fixed)
        viewModel.edit(.setInput("-12.50", field: .adjustment, id: averageID))
        viewModel.edit(.setAdjustmentMode(.percent, id: averageID))
        #expect(viewModel.editor.items.first?.draft == .average(
            numMonths: 5,
            priority: 3,
            adjustment: .percent(-12.5)
        ))
        viewModel.edit(.setAdjustmentDirection(.increase, id: averageID))
        #expect(viewModel.editor.items.first?.draft == .average(
            numMonths: 5,
            priority: 3,
            adjustment: .percent(12.5)
        ))

        viewModel.edit(.setScheduleFull(true, id: scheduleID))
        viewModel.edit(.setAdjustmentMode(.fixed, id: scheduleID))
        viewModel.edit(.setInput("20", field: .adjustment, id: scheduleID))
        #expect(viewModel.editor.items.last?.draft == .schedule(
            name: "Rent",
            scheduleId: "rent",
            priority: 3,
            full: true,
            adjustment: .fixed(20)
        ))
        #expect(viewModel.canSave)
        #expect(await viewModel.save())
        #expect(await repository.savedDrafts().last == [
            .average(numMonths: 5, priority: 3, adjustment: .percent(12.5)),
            .schedule(name: "Rent", scheduleId: "rent", priority: 3, full: true, adjustment: .fixed(20))
        ])
    }

    @Test func privacyModePreservesButDoesNotAllowNoteEdits() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [
                .monthlyFixed(amount: 400, now: now, description: "Private note")
            ])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)

        viewModel.isPrivacyModeEnabled = true
        #expect(!viewModel.canEditNotes)
        viewModel.edit(.setNoteText("Should not replace the note", id: id))
        #expect(viewModel.noteText(id: id).isEmpty)
        #expect(viewModel.editor.items.first?.draft.description == "Private note")

        viewModel.isPrivacyModeEnabled = false
        #expect(viewModel.canEditNotes)
        viewModel.edit(.setNoteText("Visible again", id: id))
        #expect(viewModel.noteText(id: id) == "Visible again")
    }

    @Test func cancellingAStaleLoadDoesNotApplyItsLateSnapshot() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        await repository.blockNextSnapshot()
        let viewModel = makeViewModel()
        let loadTask = Task { @MainActor in
            await viewModel.load(repository: repository, budgetID: "budget-1")
        }
        await repository.waitUntilSnapshotStarts()
        viewModel.cancel()
        await repository.releaseSnapshot()
        await loadTask.value

        #expect(viewModel.editor.items.isEmpty)
        #expect(!viewModel.isEditable)
        #expect(viewModel.dryRun == nil)
    }

    @Test func saveInFlightRejectsConcurrentDraftMutations() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)
        await repository.blockNextSave()

        let saveTask = Task { @MainActor in
            await viewModel.save()
        }
        await repository.waitUntilSaveStarts()
        #expect(viewModel.phase == .saving)
        #expect(!viewModel.isEditable)
        viewModel.edit(.setInput("250", field: .amount, id: id))
        viewModel.edit(.setNoteText("Must not enter the in-flight save", id: id))
        #expect(viewModel.editor.items.first?.draft == .monthlyFixed(amount: 400, now: now))
        viewModel.cancel()
        #expect(viewModel.phase == .saving)

        await repository.releaseSave()
        #expect(await saveTask.value)
        #expect(await repository.savedDrafts() == [[.monthlyFixed(amount: 400, now: now)]])
    }

    @Test func cancelThenReloadDiscardsUncommittedNoteEdits() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [
                .monthlyFixed(amount: 400, now: now, description: "Original note")
            ])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)
        viewModel.edit(.setNoteText("Discarded edit", id: id))
        #expect(viewModel.noteText(id: id) == "Discarded edit")

        viewModel.cancel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let reloadedID = try #require(viewModel.editor.items.first?.id)
        #expect(viewModel.noteText(id: reloadedID) == "Original note")
    }

    @Test func missingScheduleReferenceRemainsVisibleUntilRepaired() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [
                .schedule(name: "Deleted Rent", scheduleId: "deleted")
            ])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)

        #expect(viewModel.editor.scheduleOptions(for: id) == [
            BudgetTemplateScheduleOption(id: "deleted", name: "Deleted Rent", isAvailable: false),
            BudgetTemplateScheduleOption(id: "rent", name: "Rent")
        ])
        #expect(!viewModel.canSave)
        viewModel.edit(.setSchedule(
            "deleted",
            id: id
        ))
        #expect(viewModel.editor.items.first?.draft == .schedule(name: "Deleted Rent", scheduleId: "deleted"))

        viewModel.edit(.setSchedule("rent", id: id))
        #expect(viewModel.canSave)
        #expect(viewModel.editor.items.first?.draft == .schedule(name: "Rent", scheduleId: "rent"))
    }

    @Test func emptyListSaves() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        viewModel.edit(.remove(id: try #require(viewModel.editor.items.first?.id)))
        #expect(viewModel.canSave)
        #expect(await viewModel.save())
        #expect(await repository.savedDrafts() == [[]])
    }

    @Test func phase3AddsBalanceLimitAndRepairsRefillDependency() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(viewModel.editor.addableKinds.contains(.balanceLimit))
        #expect(viewModel.editor.addableKinds.contains(.refill))
        viewModel.edit(.add(.refill))
        #expect(!viewModel.canSave)
        #expect(viewModel.editor.addableKinds.contains(.balanceLimit))

        viewModel.edit(.add(.balanceLimit))
        #expect(viewModel.canSave)
        #expect(viewModel.editor.items.contains { if case .balanceLimit = $0.draft { true } else { false } })
        #expect(viewModel.editor.items.contains { if case .refill = $0.draft { true } else { false } })

        let limitID = try #require(
            viewModel.editor.items.first { if case .balanceLimit = $0.draft { true } else { false } }?.id
        )
        viewModel.edit(.remove(id: limitID))
        #expect(!viewModel.editor.hasBalanceLimit)
        #expect(!viewModel.canSave)
        viewModel.edit(.add(.balanceLimit))
        #expect(viewModel.canSave)
    }

    @Test func phase3FixedCadenceControlsPreserveAmountAndPriority() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, priority: 7, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        let id = try #require(viewModel.editor.items.first?.id)

        viewModel.edit(.setInput("2", field: .interval, id: id))
        viewModel.edit(.setFixedCadence(.year, id: id))
        viewModel.edit(.setFixedStartingDate(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2024, month: 2, day: 29, hour: 12)
            )!,
            id: id
        ))

        guard case .monthlyFixed(let fixed) = viewModel.editor.items.first?.draft else {
            Issue.record("Expected a fixed draft")
            return
        }
        #expect(fixed.amount == 400)
        #expect(fixed.priority == 7)
        #expect(fixed.interval == 2)
        #expect(fixed.cadence == .year)
        #expect(fixed.starting == "2024-02-29")
        #expect(viewModel.canSave)
    }

    @Test func phase3WeeklyLimitUsesFixedStartAndRetainsHold() async throws {
        var fixed = BudgetTemplateDraft.monthlyFixed(now: now)
        if case .monthlyFixed(var value) = fixed {
            value.starting = "2026-09-20"
            fixed = .monthlyFixed(value)
        }
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [fixed])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        viewModel.edit(.add(.balanceLimit))
        let limitID = try #require(viewModel.editor.items.last?.id)

        viewModel.edit(.setLimitPeriod(.weekly, id: limitID))
        #expect(viewModel.editor.limitWeekday(for: limitID) == 1)
        viewModel.edit(.setLimitWeekday(3, id: limitID))
        viewModel.edit(.setLimitHold(true, id: limitID))

        guard case .balanceLimit(let limit) = viewModel.editor.items.last?.draft else {
            Issue.record("Expected a balance limit draft")
            return
        }
        #expect(limit.start == "2026-09-22")
        #expect(limit.hold)
        #expect(limit.period == .weekly)
        #expect(viewModel.canSave)
    }

    private func makeViewModel() -> BudgetTemplateEditorViewModel {
        BudgetTemplateEditorViewModel(target: target, now: now, dryRunDelay: .zero)
    }

    private func editableSnapshot(drafts: [BudgetTemplateDraft]) -> BudgetTemplateEditorSnapshot {
        BudgetTemplateEditorSnapshot(
            categoryID: "groceries",
            categoryName: "Groceries",
            drafts: drafts,
            lock: .editable,
            schedules: [BudgetTemplateScheduleOption(id: "rent", name: "Rent")],
            currency: .usd,
            hasDefinition: !drafts.isEmpty
        )
    }
}

actor EditorTemplateRepository: BudgetRepositoryProtocol {
    var snapshot: BudgetTemplateEditorSnapshot
    private(set) var dryRunCount = 0
    private var saved: [[BudgetTemplateDraft]] = []
    private var blockSnapshot = false
    private var snapshotStarted = false
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private var blockSave = false
    private var saveStarted = false
    private var saveContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: BudgetTemplateEditorSnapshot) {
        self.snapshot = snapshot
    }

    func savedDrafts() -> [[BudgetTemplateDraft]] { saved }

    func blockNextSnapshot() { blockSnapshot = true }

    func waitUntilSnapshotStarts() async {
        while !snapshotStarted {
            await Task.yield()
        }
    }

    func releaseSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func blockNextSave() { blockSave = true }

    func waitUntilSaveStarts() async {
        while !saveStarted {
            await Task.yield()
        }
    }

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot {
        if blockSnapshot {
            blockSnapshot = false
            snapshotStarted = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                snapshotContinuation = continuation
            }
        }
        return snapshot
    }

    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun {
        dryRunCount += 1
        let perTemplate = drafts.map { draft -> Int in
            switch draft {
            case .monthlyFixed(let value):
                return BudgetCurrency.usd.minorUnits(fromDisplay: value.amount) ?? 0
            case .goal(let value):
                return BudgetCurrency.usd.minorUnits(fromDisplay: value.amount) ?? 0
            default:
                return 0
            }
        }
        return BudgetTemplateCategoryDryRun(
            budgeted: perTemplate.reduce(0, +),
            perTemplate: perTemplate
        )
    }

    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        if blockSave {
            blockSave = false
            saveStarted = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                saveContinuation = continuation
            }
        }
        saved.append(drafts)
        return Self.dummyMonth
    }

    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(
        actionID: String,
        budgetID: String
    ) async throws -> BudgetActionUndoPreview {
        BudgetActionUndoPreview(actionID: actionID, month: "", entries: [], block: nil)
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}

    private static let dummyMonth = LoadedBudgetMonth(
        availableMonths: ["2026-09"],
        selectedMonth: "2026-09",
        month: try! JSONDecoder().decode(BudgetMonth.self, from: Data(#"""
            {
              "month": "2026-09",
              "incomeAvailable": 0,
              "lastMonthOverspent": 0,
              "forNextMonth": 0,
              "totalBudgeted": 0,
              "toBudget": 0,
              "fromLastMonth": 0,
              "totalIncome": 0,
              "totalSpent": 0,
              "totalBalance": 0,
              "categoryGroups": []
            }
            """#.utf8)),
        alerts: []
    )
}
