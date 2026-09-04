import Foundation
import Observation

@MainActor
@Observable
final class BudgetTemplateEditorViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case saving
    }

    let target: BudgetTemplateEditorTarget
    let now: Date
    let dryRunDelay: Duration

    private(set) var phase: Phase = .loading
    private(set) var lock: BudgetTemplateCategoryLock = .editable
    private(set) var editor: BudgetTemplateDraftEditor
    private(set) var previewState: PreviewState = .idle
    private(set) var activeInput: BudgetTemplateEditorInputKey?
    var errorMessage: String?
    var isPrivacyModeEnabled = false
    private var didLoadSuccessfully = false

    private var loadGeneration = 0
    @ObservationIgnored private var previewCoordinator = BudgetTemplateEditorPreviewCoordinator()
    @ObservationIgnored private var session: Session?

    private struct Session {
        var repository: any BudgetRepositoryProtocol
        var budgetID: String
    }

    init(
        target: BudgetTemplateEditorTarget,
        now: Date = Date(),
        dryRunDelay: Duration = .milliseconds(200)
    ) {
        self.editor = BudgetTemplateDraftEditor(now: now)
        self.target = target
        self.now = now
        self.dryRunDelay = dryRunDelay
    }

    var isEditable: Bool {
        didLoadSuccessfully && lock.isEditable && phase == .ready
    }

    var canSave: Bool {
        isEditable
            && phase == .ready
            && editor.hasValidInputs
            && authoringIssues.isEmpty
    }

    var authoringIssues: [BudgetTemplateAuthoringIssue] {
        BudgetTemplateAuthoringValidation.issues(
            for: editor.items.map(\.draft),
            context: BudgetTemplateAuthoringContext(
                today: now,
                schedules: editor.schedules,
                incomeCategories: editor.incomeCategories
            )
        )
    }

    var authoringIssueMessages: [String] {
        activeInput == nil ? authoringIssues.map(\.message) : []
    }

    var navigationTitle: String {
        BudgetTemplateDoorKind.kind(
            hasDefinition: !editor.items.isEmpty,
            lock: lock
        ).editorTitle
    }

    enum PreviewState: Equatable {
        case idle
        case empty
        case invalid
        case editing
        case loading
        case ready(BudgetTemplateCategoryDryRun)
        case failed(String)
    }

    var dryRun: BudgetTemplateCategoryDryRun? {
        switch previewState {
        case .ready(let result): result
        case .empty: BudgetTemplateCategoryDryRun(budgeted: 0, perTemplate: [])
        default: nil
        }
    }

    var dryRunErrorMessage: String? {
        if case .failed(let message) = previewState { return message }
        return nil
    }

    var previewStatusText: String {
        switch previewState {
        case .editing: "Finish editing to update this preview."
        case .loading: "Updating preview…"
        case .invalid: "Complete the template fields to see a preview."
        case .failed: "Preview unavailable."
        case .idle, .empty, .ready: "Preview only. Your budget is unchanged."
        }
    }

    func inputShowsError(for field: BudgetTemplateEditorInputField, id: UUID) -> Bool {
        activeInput != BudgetTemplateEditorInputKey(itemID: id, field: field)
            && !editor.inputIsValid(for: field, id: id)
    }

    func inputFocusChanged(to key: BudgetTemplateEditorInputKey?) {
        guard isEditable, activeInput != key else { return }
        activeInput = key
        if previewState == .editing {
            scheduleDryRun()
        }
    }

    var canAddBalanceLimit: Bool { isEditable && editor.addableKinds.contains(.balanceLimit) }
    var canEditNotes: Bool { isEditable && !isPrivacyModeEnabled }

    func inputText(for field: BudgetTemplateEditorInputField, id: UUID) -> String {
        if isPrivacyModeEnabled && (field == .amount || field == .adjustment) { return "Hidden" }
        return editor.inputText(for: field, id: id)
    }

    func isMoneyInput(_ field: BudgetTemplateEditorInputField, id: UUID) -> Bool {
        guard let draft = editor.items.first(where: { $0.id == id })?.draft else { return false }
        return BudgetTemplateEditorInputInterpreter.monetaryAmount(for: field, draft: draft) != nil
    }

    func numericAmount(for field: BudgetTemplateEditorInputField, id: UUID) -> Decimal? {
        guard !isPrivacyModeEnabled, isMoneyInput(field, id: id) else { return nil }
        return BudgetTemplateAmountInput.numericValue(editor.inputText(for: field, id: id))
    }

    func setNumericAmount(_ amount: Decimal?, field: BudgetTemplateEditorInputField, id: UUID) {
        edit(.setInput(BudgetTemplateAmountInput.inputText(amount), field: field, id: id))
    }

    func integerValue(for field: BudgetTemplateEditorInputField, id: UUID) -> Int {
        BudgetTemplateAmountInput.parseInt(editor.inputText(for: field, id: id)) ?? 0
    }

    func setIntegerValue(_ value: Int, field: BudgetTemplateEditorInputField, id: UUID) {
        edit(.setInput(String(value), field: field, id: id))
    }

    func monthSelection(for field: BudgetTemplateEditorInputField, id: UUID) -> BudgetTemplateEditorMonth {
        BudgetTemplateEditorMonth(storage: editor.inputText(for: field, id: id)) ?? .init(now: now)
    }

    func monthTitle(for field: BudgetTemplateEditorInputField, id: UUID, locale: Locale) -> String {
        BudgetTemplateEditorMonth(storage: editor.inputText(for: field, id: id))?.title(locale: locale) ?? "Choose month"
    }

    func setMonth(_ month: BudgetTemplateEditorMonth, field: BudgetTemplateEditorInputField, id: UUID) {
        edit(.setInput(month.storage, field: field, id: id))
    }

    func monthYears(for field: BudgetTemplateEditorInputField, id: UUID) -> ClosedRange<Int> {
        monthSelection(for: field, id: id).supportedYears(now: now)
    }

    func completeMonthSelection(field: BudgetTemplateEditorInputField, id: UUID) {
        setMonth(monthSelection(for: field, id: id), field: field, id: id)
    }

    func setMonthNumber(_ month: Int, field: BudgetTemplateEditorInputField, id: UUID) {
        var selection = monthSelection(for: field, id: id)
        selection.month = month
        setMonth(selection, field: field, id: id)
    }

    func setMonthYear(_ year: Int, field: BudgetTemplateEditorInputField, id: UUID) {
        var selection = monthSelection(for: field, id: id)
        selection.year = year
        setMonth(selection, field: field, id: id)
    }

    func inputIsEnabled(_ field: BudgetTemplateEditorInputField) -> Bool {
        isEditable && !(isPrivacyModeEnabled && (field == .amount || field == .adjustment))
    }

    func noteText(id: UUID) -> String {
        isPrivacyModeEnabled ? "" : editor.noteText(id: id)
    }

    func edit(_ intent: BudgetTemplateEdit) {
        guard isEditable else { return }
        switch intent {
        case .setNoteText, .clearNote:
            guard canEditNotes else { return }
        case .setAdjustmentMode, .setAdjustmentDirection:
            guard inputIsEnabled(.adjustment) else { return }
        case .setInput(_, let field, _):
            guard inputIsEnabled(field) else { return }
        default: break
        }
        switch intent {
        case .add(let kind): editor.add(kind)
        case .remove(let id): editor.remove(id: id)
        case .setKind(let kind, let id): editor.setKind(kind, id: id)
        case .setInput(let text, let field, let id): editor.setInput(text, field: field, id: id)
        case .setNoteText(let text, let id):
            editor.setNoteText(text, id: id)
            return
        case .clearNote(let id):
            editor.clearNote(id: id)
            return
        case .setDateTargetRepeats(let value, let id): editor.setDateTargetRepeats(value, id: id)
        case .setDateTargetAnnual(let value, let id): editor.setDateTargetAnnual(value, id: id)
        case .setDateTargetEarlySpending(let value, let id): editor.setDateTargetEarlySpending(value, id: id)
        case .setFixedCadence(let value, let id): editor.setFixedCadence(value, id: id)
        case .setFixedStartingDate(let value, let id): editor.setFixedStartingDate(value, id: id)
        case .setLimitPeriod(let value, let id): editor.setLimitPeriod(value, id: id)
        case .setLimitHold(let value, let id): editor.setLimitHold(value, id: id)
        case .setLimitWeekday(let value, let id): editor.setLimitWeekday(value, id: id)
        case .setPercentageSource(let value, let id): editor.setPercentageSource(value, id: id)
        case .setPercentagePrevious(let value, let id): editor.setPercentagePrevious(value, id: id)
        case .setSchedule(let value, let id): editor.setSchedule(value, id: id)
        case .setScheduleFull(let value, let id): editor.setScheduleFull(value, id: id)
        case .setAdjustmentMode(let value, let id): editor.setAdjustmentMode(value, id: id)
        case .setAdjustmentDirection(let value, let id): editor.setAdjustmentDirection(value, id: id)
        }
        if case .setInput(_, let field, let id) = intent,
           activeInput == BudgetTemplateEditorInputKey(itemID: id, field: field) {
            previewCoordinator.cancel()
            previewState = .editing
        } else {
            scheduleDryRun()
        }
    }

    var totalContributionText: String {
        BudgetTemplateAmountInput.contributionText(
            minorUnits: dryRun?.budgeted,
            currency: editor.currency,
            randomized: isPrivacyModeEnabled,
            seed: "template-total-\(target.categoryID)"
        )
    }

    var showsContributionBreakdown: Bool {
        editor.items.count(where: { $0.draft.showsContribution }) > 1
    }

    func contributionText(at index: Int) -> String {
        let amount = dryRun.flatMap { preview in
            preview.perTemplate.indices.contains(index) ? preview.perTemplate[index] : nil
        }
        return BudgetTemplateAmountInput.contributionText(
            minorUnits: amount,
            currency: editor.currency,
            randomized: isPrivacyModeEnabled,
            seed: "template-row-\(target.categoryID)-\(index)"
        )
    }

    func load(repository: any BudgetRepositoryProtocol, budgetID: String?) async {
        loadGeneration += 1
        let requestGeneration = loadGeneration
        cancelDryRun()
        activeInput = nil
        session = nil
        didLoadSuccessfully = false
        phase = .loading
        editor = BudgetTemplateDraftEditor(now: now)
        previewState = .loading
        errorMessage = nil
        guard let budgetID else {
            errorMessage = "No budget is selected."
            phase = .ready
            previewState = .empty
            return
        }
        session = Session(repository: repository, budgetID: budgetID)
        do {
            let snapshot = try await repository.categoryTemplateEditorSnapshot(
                categoryID: target.categoryID,
                budgetID: budgetID
            )
            guard requestGeneration == loadGeneration else {
                return
            }
            lock = snapshot.lock
            editor = BudgetTemplateDraftEditor(snapshot: snapshot, now: now)
            didLoadSuccessfully = true
            phase = .ready
            scheduleDryRun()
        } catch {
            guard requestGeneration == loadGeneration else {
                return
            }
            errorMessage = error.localizedDescription
            previewState = .failed("Templates could not be loaded.")
            phase = .ready
        }
    }

    func save() async -> Bool {
        guard canSave, let session else {
            return false
        }
        loadGeneration += 1
        let requestGeneration = loadGeneration
        cancelDryRun()
        activeInput = nil
        phase = .saving
        errorMessage = nil
        do {
            _ = try await session.repository.setCategoryTemplatesAndRefresh(
                categoryID: target.categoryID,
                drafts: editor.items.map(\.draft),
                budgetID: session.budgetID,
                month: target.month
            )
            guard requestGeneration == loadGeneration else {
                return false
            }
            phase = .ready
            return true
        } catch {
            guard requestGeneration == loadGeneration else {
                return false
            }
            errorMessage = error.localizedDescription
            phase = .ready
            scheduleDryRun()
            return false
        }
    }

    func cancel() {
        guard phase != .saving else {
            return
        }
        loadGeneration += 1
        activeInput = nil
        session = nil
        didLoadSuccessfully = false
        cancelDryRun()
    }

    private func scheduleDryRun() {
        previewCoordinator.cancel()
        let drafts = editor.items.map(\.draft)
        guard !drafts.isEmpty else { previewState = .empty; return }
        guard editor.hasValidInputs, authoringIssues.isEmpty else { previewState = .invalid; return }
        guard let session else { previewState = .idle; return }
        previewState = .loading
        let target = target
        previewCoordinator.schedule(
            drafts: drafts,
            delay: dryRunDelay,
            load: { drafts in
                try await session.repository.dryRunCategoryTemplate(
                    categoryID: target.categoryID,
                    drafts: drafts,
                    budgetID: session.budgetID,
                    month: target.month
                )
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let preview):
                    self.previewState = preview.map(PreviewState.ready) ?? .empty
                case .failure(let error):
                    self.previewState = .failed(error.localizedDescription)
                }
            }
        )
    }

    private func cancelDryRun() {
        previewCoordinator.cancel()
        previewState = .idle
    }
}
