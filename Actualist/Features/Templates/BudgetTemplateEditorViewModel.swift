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
    private var dryRunGeneration = 0
    @ObservationIgnored private var dryRunTask: Task<Void, Never>?
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
        didLoadSuccessfully && lock.isEditable && phase != .loading
    }

    var canSave: Bool {
        isEditable
            && phase == .ready
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
        errorMessage = nil
        dryRunErrorMessage = nil
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
        items.append(Item(id: UUID(), draft: kind.makeDraft(now: now)))
        scheduleDryRun()
    }

    func remove(id: UUID) {
        guard isEditable else {
            return
        }
        items.removeAll { $0.id == id }
        scheduleDryRun()
    }

    func setAmount(_ text: String, id: UUID) {
        guard let amount = BudgetTemplateAmountInput.parseAmount(text, currency: currency) else {
            return
        }
        mutate(id: id) { draft in
            switch draft {
            case .monthlyFixed(var value):
                value.amount = amount
                draft = .monthlyFixed(value)
            case .goal(var value):
                value.amount = amount
                draft = .goal(value)
            default:
                break
            }
        }
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
        guard let amount = BudgetTemplateAmountInput.parseAmount(text, currency: currency) else {
            return
        }
        mutate(id: id) { draft in
            guard case .monthlyFixed(var value) = draft, var upTo = value.upTo else {
                return
            }
            upTo.amount = amount
            value.upTo = upTo
            draft = .monthlyFixed(value)
        }
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
        guard let lookBack = BudgetTemplateAmountInput.parseInt(text),
              BudgetTemplateEngine.Bounds.lookBack.contains(lookBack) else {
            return
        }
        mutate(id: id) { draft in
            guard case .copy(var value) = draft else {
                return
            }
            value.lookBack = lookBack
            draft = .copy(value)
        }
    }

    func setNumMonths(_ text: String, id: UUID) {
        guard let numMonths = BudgetTemplateAmountInput.parseInt(text),
              BudgetTemplateEngine.Bounds.numMonths.contains(numMonths) else {
            return
        }
        mutate(id: id) { draft in
            guard case .average(var value) = draft else {
                return
            }
            value.numMonths = numMonths
            draft = .average(value)
        }
    }

    func setSchedule(_ option: BudgetTemplateScheduleOption, id: UUID) {
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
        guard let weight = BudgetTemplateAmountInput.parseWeight(text),
              BudgetTemplateEngine.Bounds.weight.contains(weight) else {
            return
        }
        mutate(id: id) { draft in
            guard case .remainder(var value) = draft else {
                return
            }
            value.weight = weight
            draft = .remainder(value)
        }
    }

    func setPriority(_ text: String, id: UUID) {
        guard let priority = BudgetTemplateAmountInput.parseInt(text),
              BudgetTemplateEngine.Bounds.priority.contains(priority) else {
            return
        }
        mutate(id: id) { draft in
            switch draft {
            case .monthlyFixed(var value):
                value.priority = priority
                draft = .monthlyFixed(value)
            case .copy(var value):
                value.priority = priority
                draft = .copy(value)
            case .average(var value):
                value.priority = priority
                draft = .average(value)
            case .schedule(var value):
                value.priority = priority
                draft = .schedule(value)
            case .dateTarget(var value):
                value.priority = priority
                draft = .dateTarget(value)
            case .percentage(var value):
                value.priority = priority
                draft = .percentage(value)
            case .refill(var value):
                value.priority = priority
                draft = .refill(value)
            case .balanceLimit, .remainder, .goal:
                break
            }
        }
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
        loadGeneration += 1
        session = nil
        cancelDryRun()
    }

    private func apply(_ snapshot: BudgetTemplateEditorSnapshot) {
        lock = snapshot.lock
        currency = snapshot.currency
        schedules = snapshot.schedules
        incomeCategories = snapshot.incomeCategories
        items = snapshot.drafts.map { Item(id: UUID(), draft: $0) }
    }

    private func mutate(id: UUID, _ body: (inout BudgetTemplateDraft) -> Void) {
        guard isEditable, let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        body(&items[index].draft)
        scheduleDryRun()
    }

    private func scheduleDryRun() {
        dryRunGeneration += 1
        let requestGeneration = dryRunGeneration
        dryRunTask?.cancel()
        let drafts = items.map(\.draft)
        let delay = dryRunDelay
        dryRunTask = Task { [weak self] in
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self, requestGeneration == self.dryRunGeneration else {
                return
            }
            await self.refreshDryRun(drafts: drafts, requestGeneration: requestGeneration)
        }
    }

    private func refreshDryRun(drafts: [BudgetTemplateDraft], requestGeneration: Int) async {
        guard let session else {
            return
        }
        if drafts.isEmpty {
            dryRun = BudgetTemplateCategoryDryRun(budgeted: 0, perTemplate: [])
            dryRunErrorMessage = nil
            return
        }
        guard drafts.allSatisfy(\.isComplete) else {
            dryRun = nil
            dryRunErrorMessage = nil
            return
        }
        do {
            let preview = try await session.repository.dryRunCategoryTemplate(
                categoryID: target.categoryID,
                drafts: drafts,
                budgetID: session.budgetID,
                month: target.month
            )
            guard requestGeneration == dryRunGeneration else {
                return
            }
            dryRun = preview
            dryRunErrorMessage = nil
        } catch {
            guard requestGeneration == dryRunGeneration else {
                return
            }
            dryRun = nil
            dryRunErrorMessage = error.localizedDescription
        }
    }

    private func cancelDryRun() {
        dryRunGeneration += 1
        dryRunTask?.cancel()
        dryRunTask = nil
    }
}
