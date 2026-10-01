import Observation

@MainActor
@Observable
final class SavedTransactionFiltersCoordinator {
    typealias ApplyHandler = ([TransactionQueryCondition], TransactionQueryJoin) -> Void

    private(set) var filters: [SavedTransactionFilter] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var unavailableMessage: String?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    var nameDraft = ""
    private(set) var filterBeingDeleted: SavedTransactionFilter?
    private(set) var filterBeingRenamed: SavedTransactionFilter?

    private let mutationContext: SavedTransactionFilterMutationContext
    private let repository: any SavedTransactionFilterRepositoryProtocol
    private let conditions: [RuleCondition]?
    private let join: RuleConditionJoin
    private let onApply: ApplyHandler
    @ObservationIgnored private var generation = 0

    var currentConditionsSummary: String {
        guard let conditions else { return "Some current conditions cannot be saved here" }
        return "\(conditions.count) condition\(conditions.count == 1 ? "" : "s") · \(join.rawValue.uppercased())"
    }

    var canSaveCurrentConditions: Bool { conditions?.isEmpty == false && !isSaving }

    init(
        mutationContext: SavedTransactionFilterMutationContext,
        repository: any SavedTransactionFilterRepositoryProtocol,
        conditions: [TransactionQueryCondition],
        join: TransactionQueryJoin,
        onApply: @escaping ApplyHandler
    ) {
        self.mutationContext = mutationContext
        self.repository = repository
        let decodedConditions = conditions.compactMap(RuleCondition.init(savedQueryCondition:))
        self.conditions = decodedConditions.count == conditions.count ? decodedConditions : nil
        self.join = RuleConditionJoin(rawValue: join.rawValue) ?? .and
        self.onApply = onApply
    }

    func load() async {
        generation &+= 1
        let request = generation
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        defer {
            if generation == request { isLoading = false }
        }
        do {
            let result = try await repository.refreshSavedTransactionFilters(budgetID: mutationContext.budgetID)
            guard generation == request, !Task.isCancelled else { return }
            switch result {
            case .available(let filters):
                self.filters = filters.filter { !$0.tombstone }
                unavailableMessage = nil
            case .unavailable(let message):
                filters = []
                unavailableMessage = message
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        generation &+= 1
        isLoading = false
    }

    func apply(_ filter: SavedTransactionFilter) {
        guard filter.isSupported,
              let conditions = filter.queryConditions,
              let join = filter.queryJoin else { return }
        onApply(conditions, join)
    }

    func saveCurrentConditions() async {
        guard !isSaving, let conditions, !conditions.isEmpty else { return }
        generation &+= 1
        let request = generation
        isLoading = false
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let result = try await repository.createSavedTransactionFilter(
                context: mutationContext,
                draft: SavedTransactionFilterDraft(
                    name: nameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    conditions: conditions,
                    join: join
                )
            )
            guard generation == request, result.sessionCurrent else { return }
            acceptMutationResult(result)
            nameDraft = ""
        } catch is CancellationError {
            return
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    func beginRename(_ filter: SavedTransactionFilter) {
        guard filter.isSupported else { return }
        filterBeingRenamed = filter
        nameDraft = filter.name
        errorMessage = nil
    }

    func cancelRename() {
        filterBeingRenamed = nil
        errorMessage = nil
    }

    func confirmRename() async {
        guard let filter = filterBeingRenamed, !isSaving else { return }
        generation &+= 1
        let request = generation
        isLoading = false
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let result = try await repository.updateSavedTransactionFilter(
                context: mutationContext,
                update: SavedTransactionFilterUpdate(
                    filterID: filter.id,
                    name: nameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    conditions: nil,
                    join: nil
                )
            )
            guard generation == request, result.sessionCurrent else { return }
            acceptMutationResult(result)
            filterBeingRenamed = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
            filterBeingRenamed = filter
        }
    }

    func requestDelete(_ filter: SavedTransactionFilter) {
        filterBeingDeleted = filter
    }

    func cancelDelete() {
        filterBeingDeleted = nil
    }

    func confirmDelete() async {
        guard let filter = filterBeingDeleted, !isSaving else { return }
        filterBeingDeleted = nil
        generation &+= 1
        let request = generation
        isLoading = false
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let result = try await repository.deleteSavedTransactionFilter(
                context: mutationContext,
                filterID: filter.id
            )
            guard generation == request, result.sessionCurrent else { return }
            acceptMutationResult(result)
        } catch is CancellationError {
            return
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func acceptMutationResult(_ result: SavedTransactionFilterMutationResult) {
        if let refreshedFilters = result.filters {
            filters = refreshedFilters.filter { !$0.tombstone }
        }
        statusMessage = result.refreshPending && result.changed
            ? "Saved locally. Reopen this list to refresh it."
            : nil
    }
}
