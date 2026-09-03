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

    struct Item: Identifiable, Equatable, Sendable {
        var id: UUID
        var draft: BudgetTemplateDraft
    }

    let target: BudgetTemplateEditorTarget
    let now: Date
    let dryRunDelay: Duration

    private(set) var phase: Phase = .loading
    private(set) var lock: BudgetTemplateCategoryLock = .editable
    private(set) var items: [Item] = []
    private(set) var schedules: [BudgetTemplateScheduleOption] = []
    private(set) var incomeCategories: [BudgetTemplateIncomeOption] = []
    private(set) var currency: BudgetCurrency = .none
    private(set) var dryRun: BudgetTemplateCategoryDryRun?
    var errorMessage: String?
    var dryRunErrorMessage: String?
    var isPrivacyModeEnabled = false
    private var didLoadSuccessfully = false

    private var loadGeneration = 0
    private var fieldInputs: [BudgetTemplateEditorInputKey: BudgetTemplateEditorInputState] = [:]
    private var noteInputs: [UUID: String] = [:]
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
            && fieldInputs.values.allSatisfy(\.isValid)
            && BudgetTemplateAuthoringValidation.isValid(
                items.map(\.draft),
                context: BudgetTemplateAuthoringContext(
                    today: now,
                    schedules: schedules,
                    incomeCategories: incomeCategories
                )
            )
    }

    var navigationTitle: String {
        BudgetTemplateDoorKind.kind(
            hasDefinition: !items.isEmpty,
            lock: lock
        ).editorTitle
    }

    var addableKinds: [BudgetTemplateKind] {
        let present = Set(items.map(\.draft.kind))
        return BudgetTemplateKind.allCases.filter { kind in
            kind.isAvailableForAuthoring
                && (!kind.isSingleton || !present.contains(kind))
        }
    }

    func typeChangeKinds(for id: UUID) -> [BudgetTemplateKind] {
        let otherKinds = Set(items.filter { $0.id != id }.map(\.draft.kind))
        return BudgetTemplateKind.allCases.filter { kind in
            kind.isAvailableForAuthoring
                && (!kind.isSingleton || !otherKinds.contains(kind))
        }
    }

    func scheduleOptions(for id: UUID) -> [BudgetTemplateScheduleOption] {
        guard case .schedule(let value) = items.first(where: { $0.id == id })?.draft,
              let scheduleID = value.scheduleId,
              !schedules.contains(where: { $0.id == scheduleID }) else {
            return schedules
        }
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unavailable = BudgetTemplateScheduleOption(
            id: scheduleID,
            name: name.isEmpty ? "Unavailable schedule" : name,
            isAvailable: false
        )
        return [unavailable] + schedules
    }

    var totalContributionText: String {
        BudgetTemplateAmountInput.contributionText(
            minorUnits: dryRun?.budgeted,
            currency: currency,
            randomized: isPrivacyModeEnabled,
            seed: "template-total-\(target.categoryID)"
        )
    }

    func contributionText(at index: Int) -> String {
        let amount = dryRun.flatMap { preview in
            preview.perTemplate.indices.contains(index) ? preview.perTemplate[index] : nil
        }
        return BudgetTemplateAmountInput.contributionText(
            minorUnits: amount,
            currency: currency,
            randomized: isPrivacyModeEnabled,
            seed: "template-row-\(target.categoryID)-\(index)"
        )
    }

    func load(repository: any BudgetRepositoryProtocol, budgetID: String) async {
        loadGeneration += 1
        let requestGeneration = loadGeneration
        cancelDryRun()
        session = Session(repository: repository, budgetID: budgetID)
        didLoadSuccessfully = false
        phase = .loading
        items = []
        schedules = []
        incomeCategories = []
        dryRun = nil
        errorMessage = nil
        dryRunErrorMessage = nil
        fieldInputs.removeAll()
        noteInputs.removeAll()
        do {
            let snapshot = try await repository.categoryTemplateEditorSnapshot(
                categoryID: target.categoryID,
                budgetID: budgetID
            )
            guard requestGeneration == loadGeneration else {
                return
            }
            apply(snapshot)
            didLoadSuccessfully = true
            phase = .ready
            scheduleDryRun()
        } catch {
            guard requestGeneration == loadGeneration else {
                return
            }
            errorMessage = error.localizedDescription
            phase = .ready
        }
    }

    func add(_ kind: BudgetTemplateKind) {
        guard isEditable, addableKinds.contains(kind) else {
            return
        }
        let item = Item(id: UUID(), draft: kind.makeDraft(now: now))
        items.append(item)
        noteInputs[item.id] = item.draft.description ?? ""
        scheduleDryRun()
    }

    func remove(id: UUID) {
        guard isEditable else {
            return
        }
        items.removeAll { $0.id == id }
        noteInputs.removeValue(forKey: id)
        fieldInputs = fieldInputs.filter { $0.key.itemID != id }
        scheduleDryRun()
    }

    func setKind(_ kind: BudgetTemplateKind, id: UUID) {
        guard isEditable,
              typeChangeKinds(for: id).contains(kind),
              let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        let note = noteInputs[id]
        items[index].draft = items[index].draft.retyped(to: kind, now: now)
        if let note {
            items[index].draft = items[index].draft.updatingDescription(note)
        }
        fieldInputs = fieldInputs.filter { $0.key.itemID != id }
        scheduleDryRun()
    }

    func setAmount(_ text: String, id: UUID) {
        setInput(text, field: .amount, id: id)
    }

    func setCapEnabled(_ enabled: Bool, id: UUID) {
        mutate(id: id) { draft in
            guard case .monthlyFixed(var value) = draft else {
                return
            }
            if enabled {
                value.upTo = value.upTo ?? BudgetTemplateUpToHold(
                    amount: 0,
                    hold: false,
                    period: "monthly",
                    start: nil
                )
            } else {
                value.upTo = nil
            }
            draft = .monthlyFixed(value)
        }
    }

    func setCapAmount(_ text: String, id: UUID) {
        setInput(text, field: .capAmount, id: id)
    }

    func setHold(_ hold: Bool, id: UUID) {
        mutate(id: id) { draft in
            guard case .monthlyFixed(var value) = draft, var upTo = value.upTo else {
                return
            }
            upTo.hold = hold
            value.upTo = upTo
            draft = .monthlyFixed(value)
        }
    }

    func setLookBack(_ text: String, id: UUID) {
        setInput(text, field: .lookBack, id: id)
    }

    func setNumMonths(_ text: String, id: UUID) {
        setInput(text, field: .numMonths, id: id)
    }

    func setSchedule(_ option: BudgetTemplateScheduleOption, id: UUID) {
        guard option.isAvailable,
              schedules.contains(option) else {
            return
        }
        mutate(id: id) { draft in
            guard case .schedule(var value) = draft else {
                return
            }
            value.scheduleId = option.id
            value.name = option.name
            draft = .schedule(value)
        }
    }

    func setWeight(_ text: String, id: UUID) {
        setInput(text, field: .weight, id: id)
    }

    func setPriority(_ text: String, id: UUID) {
        setInput(text, field: .priority, id: id)
    }

    func inputText(for field: BudgetTemplateEditorInputField, id: UUID) -> String {
        if let state = fieldInputs[BudgetTemplateEditorInputKey(itemID: id, field: field)] {
            return state.text
        }
        guard let draft = items.first(where: { $0.id == id })?.draft else {
            return ""
        }
        return BudgetTemplateEditorInputInterpreter.text(
            for: field,
            draft: draft,
            currency: currency
        ) ?? ""
    }

    func inputIsValid(for field: BudgetTemplateEditorInputField, id: UUID) -> Bool {
        fieldInputs[BudgetTemplateEditorInputKey(itemID: id, field: field)]?.isValid ?? true
    }

    func setInput(_ text: String, field: BudgetTemplateEditorInputField, id: UUID) {
        guard isEditable, let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        let key = BudgetTemplateEditorInputKey(itemID: id, field: field)
        guard let updatedDraft = BudgetTemplateEditorInputInterpreter.applying(
            text,
            for: field,
            to: items[index].draft,
            currency: currency
        ) else {
            fieldInputs[key] = BudgetTemplateEditorInputState(text: text, isValid: false)
            scheduleDryRun()
            return
        }
        items[index].draft = updatedDraft
        fieldInputs[key] = BudgetTemplateEditorInputState(text: text, isValid: true)
        scheduleDryRun()
    }

    func noteText(id: UUID) -> String {
        noteInputs[id] ?? items.first(where: { $0.id == id })?.draft.description ?? ""
    }

    func hasNote(id: UUID) -> Bool {
        !noteText(id: id).isEmpty
    }

    var canEditNotes: Bool {
        isEditable && !isPrivacyModeEnabled
    }

    func setNoteText(_ text: String, id: UUID) {
        guard canEditNotes, let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        noteInputs[id] = text
        items[index].draft = items[index].draft.updatingDescription(text)
        scheduleDryRun()
    }

    func clearNote(id: UUID) {
        setNoteText("", id: id)
    }

    func save() async -> Bool {
        guard canSave, let session else {
            return false
        }
        loadGeneration += 1
        let requestGeneration = loadGeneration
        cancelDryRun()
        phase = .saving
        errorMessage = nil
        do {
            _ = try await session.repository.setCategoryTemplatesAndRefresh(
                categoryID: target.categoryID,
                drafts: items.map(\.draft),
                budgetID: session.budgetID,
                month: target.month
            )
            guard requestGeneration == loadGeneration else {
                if phase == .saving {
                    phase = .ready
                }
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
            return false
        }
    }

    func cancel() {
        guard phase != .saving else {
            return
        }
        loadGeneration += 1
        session = nil
        cancelDryRun()
        dryRun = nil
        dryRunErrorMessage = nil
    }

    private func apply(_ snapshot: BudgetTemplateEditorSnapshot) {
        lock = snapshot.lock
        currency = snapshot.currency
        schedules = snapshot.schedules
        incomeCategories = snapshot.incomeCategories
        items = snapshot.drafts.map { Item(id: UUID(), draft: $0) }
        fieldInputs.removeAll()
        noteInputs = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.draft.description ?? "") })
    }

    private func mutate(id: UUID, _ body: (inout BudgetTemplateDraft) -> Void) {
        guard isEditable, let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        body(&items[index].draft)
        fieldInputs = fieldInputs.filter { $0.key.itemID != id }
        scheduleDryRun()
    }

    private func scheduleDryRun() {
        let drafts = items.map(\.draft)
        if drafts.isEmpty {
            previewCoordinator.cancel()
            dryRun = BudgetTemplateCategoryDryRun(budgeted: 0, perTemplate: [])
            dryRunErrorMessage = nil
            return
        }
        guard drafts.allSatisfy(\.isComplete), fieldInputs.values.allSatisfy(\.isValid) else {
            previewCoordinator.cancel()
            dryRun = nil
            dryRunErrorMessage = nil
            return
        }
        previewCoordinator.schedule(
            drafts: drafts,
            delay: dryRunDelay,
            load: { [weak self] drafts in
                guard let self, let session = self.session else {
                    return nil
                }
                return try await session.repository.dryRunCategoryTemplate(
                    categoryID: self.target.categoryID,
                    drafts: drafts,
                    budgetID: session.budgetID,
                    month: self.target.month
                )
            },
            completion: { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let preview):
                    guard let preview else {
                        return
                    }
                    self.dryRun = preview
                    self.dryRunErrorMessage = nil
                case .failure(let error):
                    self.dryRun = nil
                    self.dryRunErrorMessage = error.localizedDescription
                }
            }
        )
    }

    private func cancelDryRun() {
        previewCoordinator.cancel()
    }
}
