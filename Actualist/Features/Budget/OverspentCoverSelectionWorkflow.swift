import Observation

enum BudgetOverspentCoverSource: Equatable, Sendable {
    case toBudget
    case category(id: String, name: String)

    var toMoveMoneyDestination: BudgetMoveMoneyDestination {
        switch self {
        case .toBudget:
            .toBudget
        case .category(let id, let name):
            .category(id: id, name: name)
        }
    }
}

@MainActor
@Observable
final class OverspentCoverSelectionWorkflow {
    private(set) var selectedCategoryIDs: Set<String> = []
    private(set) var isSelecting = false
    private(set) var isSubmitting = false

    var canSubmitSelection: Bool {
        !selectedCategoryIDs.isEmpty && !isSubmitting
    }

    func beginSelection(eligibleIDs: some Sequence<String>) {
        guard !isSubmitting else {
            return
        }

        isSelecting = true
        selectedCategoryIDs.formIntersection(eligibleIDs)
    }

    func endSelection() {
        isSelecting = false
        selectedCategoryIDs = []
    }

    func toggleSelection(_ id: String, isEligible: Bool) {
        guard isSelecting, isEligible, !isSubmitting else {
            return
        }

        if selectedCategoryIDs.contains(id) {
            selectedCategoryIDs.remove(id)
        } else {
            selectedCategoryIDs.insert(id)
        }
    }

    func intersectSelection(with eligibleIDs: Set<String>) {
        selectedCategoryIDs.formIntersection(eligibleIDs)
        if isSelecting, selectedCategoryIDs.isEmpty {
            isSelecting = false
        }
    }

    // Commands cover selected categories from a shared source in one batch.
    // Selected categories are excluded from single-cover eligible sources, so
    // a source can never double as a destination here.
    func coverCommands(
        options: [BudgetOverspentCategoryOption],
        source: BudgetOverspentCoverSource
    ) -> [BudgetMoveMoneyCommand] {
        guard isSelecting, !selectedCategoryIDs.isEmpty else {
            return []
        }

        return options.compactMap { option in
            guard selectedCategoryIDs.contains(option.id),
                  option.category.balance < 0 else {
                return nil
            }

            let amount = -option.category.balance
            switch source {
            case .toBudget:
                return BudgetMoveMoneyCommand(
                    fromCategoryID: nil,
                    toCategoryID: option.id,
                    amount: amount
                )
            case .category(let id, _):
                return BudgetMoveMoneyCommand(
                    fromCategoryID: id,
                    toCategoryID: option.id,
                    amount: amount
                )
            }
        }
    }

    func markSubmitting() {
        isSubmitting = true
    }

    // A successfully submitted selection is resolved by definition: the batch
    // covered every selected option in one repository mutation.
    @discardableResult
    func finishSubmission(success: Bool) -> Bool {
        isSubmitting = false
        if success {
            endSelection()
        }
        return success
    }
}
