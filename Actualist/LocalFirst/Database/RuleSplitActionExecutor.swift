import Foundation

struct RuleEvaluationSplit: Equatable, Sendable {
    var categoryID: String?
    var amount: Int
}

enum RuleSplitActionExecutor {
    static func applies(to actions: [RuleAction]) -> Bool {
        actions.contains { action in
            action.operation == "set-split-amount" || action.splitIndex != nil
        }
    }

    static func apply(_ actions: [RuleAction], to context: inout RuleEvaluationContext) {
        let parentActions = actions.filter { $0.splitIndex == nil }
        if parentActions.contains(where: { $0.operation == "delete-transaction" }) {
            context.deletesTransaction = true
            return
        }
        for action in parentActions {
            RuleConditionEvaluator.apply(action: action, context: &context)
        }

        let childActions = actions.filter { $0.splitIndex != nil }
        guard let maxIndex = childActions.compactMap(\.splitIndex).max() else {
            return
        }

        var splits = Array(
            repeating: RuleEvaluationSplit(categoryID: nil, amount: 0),
            count: maxIndex + 1
        )
        var methods = Array(repeating: "", count: splits.count)

        for action in childActions {
            guard let index = action.splitIndex, splits.indices.contains(index) else {
                continue
            }
            if action.operation == "set-split-amount" {
                let method = action.splitMethod ?? ""
                methods[index] = method
                if method == "fixed-amount", let amount = numericAmount(action.value) {
                    splits[index].amount = signed(amount, like: context.amount)
                }
            } else if action.operation == "set", action.field == "category" {
                splits[index].categoryID = stringID(action.value)
            }
        }

        let fixedTotal = zip(splits, methods).reduce(0) { sum, item in
            item.1 == "fixed-amount" ? sum + item.0.amount : sum
        }
        let remainingAfterFixed = context.amount - fixedTotal

        for action in childActions where action.splitMethod == "fixed-percent" {
            guard let splitIndex = action.splitIndex,
                  splits.indices.contains(splitIndex),
                  let percent = numericAmount(action.value) else {
                continue
            }
            let raw = Double(remainingAfterFixed) * (Double(percent) / 100)
            splits[splitIndex].amount = Int(raw.rounded(.toNearestOrAwayFromZero))
        }

        let remainderIndexes = splits.indices.filter { methods[$0] == "remainder" }
        if !remainderIndexes.isEmpty {
            let assigned = splits.indices.reduce(0) { sum, index in
                methods[index] == "remainder" ? sum : sum + splits[index].amount
            }
            let remaining = context.amount - assigned
            let each = remaining / remainderIndexes.count
            for index in remainderIndexes {
                splits[index].amount = each
            }
            splits[remainderIndexes[remainderIndexes.count - 1]].amount += remaining - (each * remainderIndexes.count)
        }

        context.splits = splits
        context.categoryID = nil
        context.categoryName = nil
        context.categoryGroupID = nil
        context.categoryGroupName = nil
    }

    private static func signed(_ amount: Int, like parent: Int) -> Int {
        if parent < 0, amount > 0 { return -amount }
        if parent > 0, amount < 0 { return -amount }
        return amount
    }

    private static func numericAmount(_ value: RuleJSONValue) -> Int? {
        switch value {
        case .number(let number):
            guard number.isFinite else { return nil }
            return Int(number.rounded(.toNearestOrAwayFromZero))
        case .string(let text):
            guard let number = Double(text) else { return nil }
            return Int(number.rounded(.toNearestOrAwayFromZero))
        default:
            return nil
        }
    }

    private static func stringID(_ value: RuleJSONValue) -> String? {
        if case .string(let string) = value { return string.isEmpty ? nil : string }
        return nil
    }
}
