import Foundation

enum BudgetTemplateEditorInputField: Hashable, Sendable {
    case amount
    case percent
    case interval
    case repeatInterval
    case lookBack
    case numMonths
    case priority
    case weight
    case targetMonth
    case spendStartMonth
}

struct BudgetTemplateEditorInputKey: Hashable, Sendable {
    let itemID: UUID
    let field: BudgetTemplateEditorInputField
}

struct BudgetTemplateEditorInputState: Equatable, Sendable {
    var text: String
    var isValid: Bool
}

/// Keeps visible text and draft interpretation together without putting
/// parsing or command construction in SwiftUI fields.
enum BudgetTemplateEditorInputInterpreter {
    static func text(
        for field: BudgetTemplateEditorInputField,
        draft: BudgetTemplateDraft,
        currency: BudgetCurrency
    ) -> String? {
        switch (field, draft) {
        case (.amount, .monthlyFixed(let value)):
            BudgetTemplateAmountInput.formatAmount(value.amount, currency: currency)
        case (.amount, .goal(let value)):
            BudgetTemplateAmountInput.formatAmount(value.amount, currency: currency)
        case (.amount, .balanceLimit(let value)):
            BudgetTemplateAmountInput.formatAmount(value.amount, currency: currency)
        case (.percent, .percentage(let value)):
            String(value.percent)
        case (.interval, .monthlyFixed(let value)):
            String(value.interval)
        case (.repeatInterval, .dateTarget(let value)):
            value.repeatInterval.map(String.init)
        case (.lookBack, .copy(let value)):
            String(value.lookBack)
        case (.numMonths, .average(let value)):
            String(value.numMonths)
        case (.priority, .monthlyFixed(let value)):
            String(value.priority)
        case (.priority, .copy(let value)):
            String(value.priority)
        case (.priority, .average(let value)):
            String(value.priority)
        case (.priority, .schedule(let value)):
            String(value.priority)
        case (.priority, .dateTarget(let value)):
            String(value.priority)
        case (.priority, .percentage(let value)):
            String(value.priority)
        case (.priority, .refill(let value)):
            String(value.priority)
        case (.targetMonth, .dateTarget(let value)):
            value.month
        case (.spendStartMonth, .dateTarget(let value)):
            value.fromMonth ?? ""
        case (.weight, .remainder(let value)):
            weightText(value.weight)
        default:
            nil
        }
    }

    static func applying(
        _ text: String,
        for field: BudgetTemplateEditorInputField,
        to draft: BudgetTemplateDraft,
        currency: BudgetCurrency
    ) -> BudgetTemplateDraft? {
        switch field {
        case .amount:
            guard let amount = BudgetTemplateAmountInput.parseAmount(text, currency: currency) else {
                return nil
            }
            switch draft {
            case .monthlyFixed(var value):
                value.amount = amount
                return .monthlyFixed(value)
            case .goal(var value):
                value.amount = amount
                return .goal(value)
            case .balanceLimit(var value):
                value.amount = amount
                return .balanceLimit(value)
            default:
                return nil
            }
        case .percent:
            guard let percent = BudgetTemplateAmountInput.parsePercentage(text),
                  case .percentage(var value) = draft else {
                return nil
            }
            value.percent = percent
            return .percentage(value)
        case .interval:
            guard let interval = BudgetTemplateAmountInput.parseInt(text),
                  BudgetTemplateEngine.Bounds.periodInterval.contains(interval),
                  case .monthlyFixed(var value) = draft else {
                return nil
            }
            value.interval = interval
            return .monthlyFixed(value)
        case .repeatInterval:
            guard let interval = BudgetTemplateAmountInput.parseInt(text),
                  BudgetTemplateEngine.Bounds.repeatInterval.contains(interval),
                  case .dateTarget(var value) = draft else {
                return nil
            }
            value.repeatInterval = interval
            return .dateTarget(value)
        case .lookBack:
            guard let lookBack = BudgetTemplateAmountInput.parseInt(text),
                  BudgetTemplateEngine.Bounds.lookBack.contains(lookBack),
                  case .copy(var value) = draft else {
                return nil
            }
            value.lookBack = lookBack
            return .copy(value)
        case .numMonths:
            guard let numMonths = BudgetTemplateAmountInput.parseInt(text),
                  BudgetTemplateEngine.Bounds.numMonths.contains(numMonths),
                  case .average(var value) = draft else {
                return nil
            }
            value.numMonths = numMonths
            return .average(value)
        case .priority:
            guard let priority = BudgetTemplateAmountInput.parseInt(text),
                  BudgetTemplateEngine.Bounds.priority.contains(priority) else {
                return nil
            }
            switch draft {
            case .monthlyFixed(var value):
                value.priority = priority
                return .monthlyFixed(value)
            case .copy(var value):
                value.priority = priority
                return .copy(value)
            case .average(var value):
                value.priority = priority
                return .average(value)
            case .schedule(var value):
                value.priority = priority
                return .schedule(value)
            case .dateTarget(var value):
                value.priority = priority
                return .dateTarget(value)
            case .percentage(var value):
                value.priority = priority
                return .percentage(value)
            case .refill(var value):
                value.priority = priority
                return .refill(value)
            case .balanceLimit, .remainder, .goal:
                return nil
            }
        case .weight:
            guard let weight = BudgetTemplateAmountInput.parseWeight(text),
                  BudgetTemplateEngine.Bounds.weight.contains(weight),
                  case .remainder(var value) = draft else {
                return nil
            }
            value.weight = weight
            return .remainder(value)
        case .targetMonth, .spendStartMonth:
            guard let month = try? BudgetTemplateCalendar.parseMonth(text),
                  case .dateTarget(var value) = draft else {
                return nil
            }
            let monthID = BudgetTemplateCalendar.monthID(month)
            if field == .targetMonth {
                value.month = monthID
            } else {
                value.fromMonth = monthID
            }
            return .dateTarget(value)
        }
    }

    private static func weightText(_ weight: Double) -> String {
        if weight.rounded() == weight {
            return String(Int(weight))
        }
        return String(weight)
    }
}
