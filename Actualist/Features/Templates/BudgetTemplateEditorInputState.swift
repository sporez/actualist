import Foundation

enum BudgetTemplateEditorInputField: Hashable, Sendable {
    case amount
    case capAmount
    case lookBack
    case numMonths
    case priority
    case weight
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
        case (.capAmount, .monthlyFixed(let value)):
            value.upTo.map { BudgetTemplateAmountInput.formatAmount($0.amount, currency: currency) }
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
            default:
                return nil
            }
        case .capAmount:
            guard let amount = BudgetTemplateAmountInput.parseAmount(text, currency: currency),
                  case .monthlyFixed(var value) = draft,
                  var upTo = value.upTo else {
                return nil
            }
            upTo.amount = amount
            value.upTo = upTo
            return .monthlyFixed(value)
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
        }
    }

    private static func weightText(_ weight: Double) -> String {
        if weight.rounded() == weight {
            return String(Int(weight))
        }
        return String(weight)
    }
}
