import Observation

@MainActor
@Observable
final class BudgetCategoryDeletionWorkflow {
    struct Destination: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let groupName: String
        let isIncome: Bool
        let hidden: Bool
    }

    enum Target: Equatable, Sendable {
        case category(id: String, name: String, isIncome: Bool)
        case group(id: String, name: String, isIncome: Bool, categoryIDs: [String])

        var isIncome: Bool {
            switch self {
            case .category(_, _, let isIncome), .group(_, _, let isIncome, _): isIncome
            }
        }

        var name: String {
            switch self {
            case .category(_, let name, _), .group(_, let name, _, _): name
            }
        }

        var deleteTitle: String {
            switch self {
            case .category: "Delete Category"
            case .group: "Delete Group"
            }
        }

        var reviewMessage: String {
            let transfer = "Are you sure you want to delete it? If so, you must select another category to transfer existing transactions and balance to."
            switch self {
            case .category:
                let use = isIncome
                    ? "\(name) is used by existing transactions or it has a positive leftover balance currently."
                    : "\(name) is used by existing transactions."
                return "\(use) \(transfer)"
            case .group:
                let use = isIncome
                    ? "Categories in the group \(name) are used by existing transactions or it has a positive leftover balance currently."
                    : "Categories in the group \(name) are used by existing transactions."
                return "\(use) \(transfer)"
            }
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case checking
        case ready(requiresTransfer: Bool)
        case submitting
    }

    private(set) var state: State = .idle
    private(set) var target: Target?
    private(set) var destinations: [Destination] = []
    private(set) var selectedDestinationID: String?
    private(set) var errorMessage: String?
    private var generation = 0

    var isBusy: Bool {
        state == .checking || state == .submitting
    }

    func prepareCategory(
        _ category: BudgetMonthCategory,
        groups: [BudgetMonthCategoryGroup],
        isTrackingBudget: Bool,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async {
        let target = Target.category(id: category.id, name: category.name, isIncome: category.isIncome)
        await prepare(
            target: target, excludedCategoryIDs: [category.id], groups: groups,
            isTrackingBudget: isTrackingBudget, budgetID: budgetID
        ) {
            try await repository.categoryNeedsTransfer(categoryID: category.id, budgetID: $0)
        }
    }

    func prepareGroup(
        _ group: BudgetMonthCategoryGroup,
        groups: [BudgetMonthCategoryGroup],
        isTrackingBudget: Bool,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async {
        let categoryIDs = group.categories.map(\.id)
        let target = Target.group(
            id: group.id, name: group.name, isIncome: group.isIncome, categoryIDs: categoryIDs
        )
        await prepare(
            target: target, excludedCategoryIDs: Set(categoryIDs), groups: groups,
            isTrackingBudget: isTrackingBudget, budgetID: budgetID
        ) { budgetID in
            for categoryID in categoryIDs {
                if try await repository.categoryNeedsTransfer(categoryID: categoryID, budgetID: budgetID) {
                    return true
                }
            }
            return false
        }
    }

    func selectDestination(_ categoryID: String?) {
        guard categoryID == nil || destinations.contains(where: { $0.id == categoryID }) else { return }
        selectedDestinationID = categoryID
        errorMessage = nil
    }

    func cancel() {
        generation += 1
        state = .idle
        target = nil
        destinations = []
        selectedDestinationID = nil
        errorMessage = nil
    }

    func delete(
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard case .ready(let requiresTransfer) = state, let target else { return nil }
        guard let selectedMonth, let budgetID else {
            errorMessage = "No budget is open."
            return nil
        }
        if requiresTransfer, selectedDestinationID == nil {
            errorMessage = "Choose a category to receive the existing activity and budget."
            return nil
        }
        generation += 1
        let token = generation
        state = .submitting
        errorMessage = nil
        do {
            let loaded: LoadedBudgetMonth
            switch target {
            case .category(let id, _, _):
                loaded = try await repository.deleteCategoryAndRefresh(
                    categoryID: id, transferCategoryID: selectedDestinationID,
                    budgetID: budgetID, month: selectedMonth
                )
            case .group(let id, _, _, _):
                loaded = try await repository.deleteCategoryGroupAndRefresh(
                    groupID: id, transferCategoryID: selectedDestinationID,
                    budgetID: budgetID, month: selectedMonth
                )
            }
            guard token == generation else { return nil }
            cancel()
            return loaded
        } catch {
            guard token == generation else { return nil }
            state = .ready(requiresTransfer: requiresTransfer)
            errorMessage = error.userFacingMessage
            return nil
        }
    }

    private func prepare(
        target: Target,
        excludedCategoryIDs: Set<String>,
        groups: [BudgetMonthCategoryGroup],
        isTrackingBudget: Bool,
        budgetID: String?,
        needsTransfer: (String) async throws -> Bool
    ) async {
        guard isTrackingBudget || !target.isIncome else {
            cancel()
            errorMessage = "Income categories cannot be managed in an envelope budget."
            return
        }
        guard let budgetID else {
            cancel()
            errorMessage = "No budget is open."
            return
        }
        generation += 1
        let token = generation
        state = .checking
        self.target = target
        destinations = groups
            .filter { $0.isIncome == target.isIncome }
            .flatMap { group in
                group.categories.compactMap { category in
                    guard category.isIncome == target.isIncome,
                          !excludedCategoryIDs.contains(category.id) else { return nil }
                    return Destination(
                        id: category.id, name: category.name, groupName: group.name,
                        isIncome: category.isIncome, hidden: group.hidden == true || category.hidden == true
                    )
                }
            }
        selectedDestinationID = nil
        errorMessage = nil
        do {
            let required = try await needsTransfer(budgetID)
            guard token == generation else { return }
            state = .ready(requiresTransfer: required)
        } catch {
            guard token == generation else { return }
            state = .idle
            self.target = nil
            destinations = []
            selectedDestinationID = nil
            errorMessage = error.userFacingMessage
        }
    }
}
