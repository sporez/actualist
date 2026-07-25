import Foundation

enum BudgetAssignmentInputMode: Equatable {
    case direct
    case addition
    case subtraction
}

enum BudgetAssignmentSubmissionState: Equatable {
    case draft
    case submitting
    case refetching
    case failed(String)

    var isSubmitting: Bool {
        switch self {
        case .submitting, .refetching:
            true
        case .draft, .failed:
            false
        }
    }
}

struct BudgetAssignmentDraft: Equatable {
    let categoryID: String
    let originalBudgeted: Int
    var inputDigits: String
    var inputMode: BudgetAssignmentInputMode
    var submissionState: BudgetAssignmentSubmissionState = .draft

    var isSubmitting: Bool {
        submissionState.isSubmitting
    }

    var inputAmount: Int {
        Int(inputDigits) ?? 0
    }

    var finalBudgeted: Int {
        validatedFinalBudgeted ?? originalBudgeted
    }

    var validatedFinalBudgeted: Int? {
        switch inputMode {
        case .direct:
            inputDigits.isEmpty ? originalBudgeted : inputAmount
        case .addition:
            checkedAdd(originalBudgeted, inputAmount)
        case .subtraction:
            checkedSubtract(originalBudgeted, inputAmount)
        }
    }

    var signedDelta: Int {
        switch inputMode {
        case .direct:
            0
        case .addition:
            inputAmount
        case .subtraction:
            -inputAmount
        }
    }
}

struct BudgetAssignedAmountDisplay: Equatable {
    let primaryText: String
    let secondaryText: String?
    let isEditing: Bool
    let isDeltaMode: Bool
}

enum BudgetMoveMoneyDestination: Equatable, Sendable {
    case toBudget
    case category(id: String, name: String)

    var categoryID: String? {
        switch self {
        case .toBudget:
            nil
        case .category(let id, _):
            id
        }
    }

    var id: String {
        switch self {
        case .toBudget:
            "to-budget"
        case .category(let id, _):
            id
        }
    }

    var title: String {
        switch self {
        case .toBudget:
            "To Budget"
        case .category(_, let name):
            name.actualistCategoryNameParts.name
        }
    }
}

enum BudgetMoveMoneyDirection: Equatable, Sendable {
    case outOfFocusedCategory
    case intoFocusedCategory

    var headerTitle: String {
        switch self {
        case .outOfFocusedCategory:
            "Move From"
        case .intoFocusedCategory:
            "Move To"
        }
    }

    var counterpartyPrompt: String {
        switch self {
        case .outOfFocusedCategory:
            "To"
        case .intoFocusedCategory:
            "From"
        }
    }

    var arrowSystemImage: String {
        switch self {
        case .outOfFocusedCategory:
            "arrow.down.circle.fill"
        case .intoFocusedCategory:
            "arrow.up.circle.fill"
        }
    }

    var toggled: BudgetMoveMoneyDirection {
        switch self {
        case .outOfFocusedCategory:
            .intoFocusedCategory
        case .intoFocusedCategory:
            .outOfFocusedCategory
        }
    }
}

struct BudgetMoveMoneyAllocation: Identifiable, Equatable, Sendable {
    let id: String
    let destination: BudgetMoveMoneyDestination
    var amount: Int
}

struct BudgetMoveMoneyDraft: Equatable {
    let focusedCategoryID: String
    let focusedCategoryName: String
    let focusedAvailable: Int
    var direction: BudgetMoveMoneyDirection = .outOfFocusedCategory
    var amount: Int = 0
    var destination: BudgetMoveMoneyDestination?
    var allocations: [BudgetMoveMoneyAllocation] = []
    var focusedAllocationID: String?
    var submissionState: BudgetAssignmentSubmissionState = .draft

    var isSubmitting: Bool {
        submissionState.isSubmitting
    }

    var totalAllocatedAmount: Int {
        validatedTotalAllocatedAmount ?? Int.max
    }

    var validatedTotalAllocatedAmount: Int? {
        allocations.reduce(Optional(0)) { total, allocation in
            guard let total else { return nil }
            return checkedAdd(total, allocation.amount)
        }
    }
}

private func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? nil : result.partialValue
}

private func checkedSubtract(_ lhs: Int, _ rhs: Int) -> Int? {
    let result = lhs.subtractingReportingOverflow(rhs)
    return result.overflow ? nil : result.partialValue
}

struct BudgetMoveMoneyDestinationOption: Identifiable, Equatable {
    let id: String
    let title: String
    let amount: Int
    let valueText: String
    let destination: BudgetMoveMoneyDestination
}

struct BudgetMoveMoneyDestinationGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let options: [BudgetMoveMoneyDestinationOption]
}

struct BudgetOverspentCategoryOption: Identifiable, Equatable {
    let id: String
    let groupName: String
    let category: BudgetMonthCategory

    var categoryName: String {
        category.name.actualistCategoryNameParts.name
    }

    var amountText: String {
        category.balance.actualMoney.formatted()
    }
}
