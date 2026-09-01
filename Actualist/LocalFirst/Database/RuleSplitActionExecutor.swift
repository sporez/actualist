import Foundation

/// Actual 26.8.1 `execActions` / `execSplitActions` for rule-created families.
enum RuleSplitActionExecutor {
    enum Outcome: Equatable {
        case applied(SplitTransactionRecord)
        case failedClosed
    }

    static func execActions(
        _ actions: [RuleAction],
        transaction: SplitTransactionRecord,
        formula: RuleFormulaContext = .empty,
        idGenerator: @escaping () -> String = { UUID().uuidString }
    ) -> Outcome {
        let parentActions = actions.filter { ($0.splitIndex ?? 0) == 0 }
        let childActions = actions.filter { ($0.splitIndex ?? 0) != 0 }
        let totalSplitCount = (actions.map { $0.splitIndex ?? 0 }.max() ?? 0) + 1

        var result = transaction
        for action in parentActions {
            switch apply(action, to: &result, formula: formula) {
            case .ok:
                break
            case .failedClosed:
                return .failedClosed
            }
        }
        if totalSplitCount == 1 {
            return .applied(result)
        }
        if result.isChild {
            return .applied(result)
        }
        return execSplitActions(
            childActions,
            parent: result,
            formula: formula,
            idGenerator: idGenerator
        )
    }

    static func apply(actions: [RuleAction], context: inout RuleEvaluationContext) -> Bool {
        guard let record = record(from: context) else { return false }
        switch execActions(actions, transaction: record, formula: formulaContext(from: context)) {
        case .failedClosed:
            return false
        case .applied(let result):
            write(result, into: &context)
            return true
        }
    }

    private static func execSplitActions(
        _ actions: [RuleAction],
        parent: SplitTransactionRecord,
        formula: RuleFormulaContext,
        idGenerator: @escaping () -> String
    ) -> Outcome {
        var rows = SplitTransactionFamilyOps.splitTransaction(
            [parent],
            id: parent.id,
            idGenerator: idGenerator
        ).data

        for action in actions {
            let splitTransactionIndex = (action.splitIndex ?? 0) + 1
            if splitTransactionIndex >= rows.count {
                rows = SplitTransactionFamilyOps.addSplitTransaction(
                    rows,
                    id: parent.id,
                    idGenerator: idGenerator
                ).data
            }
            guard splitTransactionIndex < rows.count else { return .failedClosed }
            switch apply(action, to: &rows[splitTransactionIndex], formula: formula, parentAmount: parent.amount) {
            case .ok:
                break
            case .failedClosed:
                return .failedClosed
            }
        }

        let splitAmountActions = actions.filter { $0.operation == "set-split-amount" }
        let remainingAfterFixedAmounts = splitRemainder(rows)
        for action in splitAmountActions where action.splitMethod == "fixed-percent" {
            let splitTransactionIndex = (action.splitIndex ?? 0) + 1
            guard splitTransactionIndex < rows.count,
                  let percent = numericValue(action.value) else { return .failedClosed }
            do {
                rows[splitTransactionIndex].amount = try RuleFormulaEvaluator.javascriptRound(
                    Double(remainingAfterFixedAmounts) * (percent / 100)
                )
            } catch {
                return .failedClosed
            }
        }

        let remainderActions = splitAmountActions.filter { $0.splitMethod == "remainder" }
        if !remainderActions.isEmpty {
            let remainingAfterFixedPercents = splitRemainder(rows)
            let amountPerRemainderSplit: Int
            do {
                amountPerRemainderSplit = try RuleFormulaEvaluator.javascriptRound(
                    Double(remainingAfterFixedPercents) / Double(remainderActions.count)
                )
            } catch {
                return .failedClosed
            }
            var lastNonFixedTransactionIndex = -1
            for action in remainderActions {
                let splitTransactionIndex = (action.splitIndex ?? 0) + 1
                guard splitTransactionIndex < rows.count else { return .failedClosed }
                rows[splitTransactionIndex].amount = amountPerRemainderSplit
                lastNonFixedTransactionIndex = max(lastNonFixedTransactionIndex, splitTransactionIndex)
            }
            if lastNonFixedTransactionIndex >= 0 {
                rows[lastNonFixedTransactionIndex].amount += splitRemainder(rows)
            }
        }

        guard rows.count > 1 else { return .failedClosed }
        rows.remove(at: 1)
        return .applied(SplitTransactionFamilyOps.recalculateSplit(
            SplitTransactionFamilyOps.groupTransaction(rows)
        ))
    }

    private enum ApplyResult {
        case ok
        case failedClosed
    }

    private static func apply(
        _ action: RuleAction,
        to record: inout SplitTransactionRecord,
        formula: RuleFormulaContext,
        parentAmount: Int? = nil
    ) -> ApplyResult {
        var fields = formula.fields
        fields["amount"] = .number(Double(record.amount))
        fields["account"] = .string(record.account ?? "")
        fields["date"] = .string(record.date ?? "")
        fields["category"] = .string(record.category ?? "")
        fields["payee"] = .string(record.payee ?? "")
        fields["notes"] = .string(record.notes ?? "")
        fields["cleared"] = .bool(record.cleared ?? false)
        fields["reconciled"] = .bool(record.reconciled ?? false)
        fields["is_parent"] = .bool(record.isParent)
        fields["is_child"] = .bool(record.isChild)
        fields["parent_id"] = .string(record.parentID ?? "")
        if let sortOrder = record.sortOrder {
            fields["sort_order"] = .number(sortOrder)
        }
        if let parentAmount {
            fields["parent_amount"] = .number(Double(parentAmount))
        }
        let formulaContext = RuleFormulaContext(
            fields: fields,
            balanceOfPrefetch: formula.balanceOfPrefetch,
            today: formula.today
        )

        switch action.operation {
        case "set":
            if case .string(let formulaText) = action.options?["formula"] {
                switch evaluateSetFormula(formulaText, field: action.field, context: formulaContext) {
                case .failedClosed:
                    return .failedClosed
                case .ok(let value):
                    assign(field: action.field, value: value, to: &record)
                    return .ok
                }
            }
            assign(field: action.field, value: action.value, to: &record)
            return .ok
        case "set-split-amount":
            switch action.splitMethod {
            case "fixed-amount":
                guard let amount = integerAmount(action.value) else { return .failedClosed }
                record.amount = amount
            case "formula":
                guard case .string(let formulaText) = action.options?["formula"] else {
                    return .ok
                }
                do {
                    let result = try RuleFormulaEvaluator.evaluate(formulaText, context: formulaContext)
                    guard let number = result.number,
                          let amount = integerAmount(.number(number)) else {
                        return .failedClosed
                    }
                    record.amount = amount
                } catch {
                    return .failedClosed
                }
            default:
                break
            }
            return .ok
        case "prepend-notes":
            if case .string(let value) = action.value {
                record.notes = record.notes.map { value + $0 } ?? value
            }
            return .ok
        case "append-notes":
            if case .string(let value) = action.value {
                record.notes = record.notes.map { $0 + value } ?? value
            }
            return .ok
        case "delete-transaction":
            record.deleted = true
            return .ok
        case "link-schedule":
            return .ok
        default:
            return .failedClosed
        }
    }

    private enum FormulaAssign {
        case ok(RuleJSONValue)
        case failedClosed
    }

    private static func evaluateSetFormula(
        _ formulaText: String,
        field: String?,
        context: RuleFormulaContext
    ) -> FormulaAssign {
        do {
            let result = try RuleFormulaEvaluator.evaluate(formulaText, context: context)
            switch field {
            case "amount":
                guard let number = result.number else { return .failedClosed }
                return .ok(.number(number))
            case "notes", "payee", "category", "account", "date":
                switch result {
                case .string(let text): return .ok(.string(text))
                case .number(let number): return .ok(.string(String(Int(number))))
                case .bool(let enabled): return .ok(.string(enabled ? "true" : "false"))
                }
            case "cleared":
                if case .bool(let enabled) = result { return .ok(.bool(enabled)) }
                return .failedClosed
            default:
                return .failedClosed
            }
        } catch {
            return .failedClosed
        }
    }

    private static func assign(field: String?, value: RuleJSONValue, to record: inout SplitTransactionRecord) {
        switch field {
        case "account":
            if case .string(let account) = value { record.account = account }
        case "amount":
            if let amount = integerAmount(value) { record.amount = amount }
        case "category":
            record.category = stringOrNil(value)
        case "date":
            if case .string(let date) = value { record.date = date }
        case "notes":
            record.notes = stringOrNil(value)
        case "payee", "description":
            record.payee = stringOrNil(value)
        case "cleared":
            if case .bool(let cleared) = value { record.cleared = cleared }
        default:
            break
        }
    }

    private static func splitRemainder(_ rows: [SplitTransactionRecord]) -> Int {
        SplitTransactionFamilyOps.recalculateSplit(
            SplitTransactionFamilyOps.groupTransaction(rows)
        ).error?.difference ?? 0
    }

    private static func integerAmount(_ value: RuleJSONValue) -> Int? {
        switch value {
        case .number(let number):
            guard number.isFinite, number >= Double(Int.min), number <= Double(Int.max) else {
                return nil
            }
            return Int(number)
        case .string(let text):
            return Int(text)
        default:
            return nil
        }
    }

    private static func numericValue(_ value: RuleJSONValue) -> Double? {
        switch value {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }

    private static func stringOrNil(_ value: RuleJSONValue) -> String? {
        if case .string(let string) = value { return string.isEmpty ? nil : string }
        return nil
    }

    private static func record(from context: RuleEvaluationContext) -> SplitTransactionRecord? {
        SplitTransactionRecord(
            id: context.evaluationID,
            amount: context.amount,
            account: context.accountID,
            date: dateString(context.date),
            category: context.categoryID,
            payee: context.payeeID,
            notes: context.notes,
            cleared: context.cleared,
            reconciled: context.reconciled,
            startingBalance: context.startingBalance,
            sortOrder: context.sortOrder,
            isParent: context.isParent,
            isChild: context.isChild,
            parentID: context.parentID
        )
    }

    private static func write(_ record: SplitTransactionRecord, into context: inout RuleEvaluationContext) {
        context.amount = record.amount
        context.accountID = record.account ?? context.accountID
        context.accountName = context.accountNames[context.accountID] ?? context.accountName
        context.accountIsOffBudget = context.offBudgetAccountIDs.contains(context.accountID)
        if let date = record.date.flatMap(dateValue) {
            context.date = date
        }
        context.categoryID = record.category
        context.categoryName = context.categoryID.flatMap { context.categoryNames[$0] }
        context.categoryGroupID = context.categoryID.flatMap { context.categoryGroupsByCategoryID[$0] }
        context.categoryGroupName = context.categoryGroupID.flatMap { context.categoryGroupNames[$0] }
        context.payeeID = record.payee
        context.payeeName = context.payeeID.flatMap { context.payeeNames[$0] } ?? ""
        context.notes = record.notes
        context.cleared = record.cleared ?? false
        context.reconciled = record.reconciled ?? false
        context.isParent = record.isParent
        context.isChild = record.isChild
        context.parentID = record.parentID
        context.sortOrder = record.sortOrder
        context.startingBalance = record.startingBalance ?? false
        context.deletesTransaction = record.deleted
        context.splits = record.subtransactions.map { child in
            RuleEvaluationSplit(
                id: child.id,
                categoryID: child.category,
                amount: child.amount,
                payeeID: child.payee,
                notes: child.notes,
                sortOrder: child.sortOrder
            )
        }
    }

    private static func formulaContext(from context: RuleEvaluationContext) -> RuleFormulaContext {
        RuleFormulaContext(
            fields: [
                "amount": .number(Double(context.amount)),
                "account": .string(context.accountID),
                "account_name": .string(context.accountName),
                "category": .string(context.categoryID ?? ""),
                "category_name": .string(context.categoryName ?? ""),
                "payee": .string(context.payeeID ?? ""),
                "notes": .string(context.notes ?? ""),
                "imported_payee": .string(context.importedPayee ?? ""),
                "cleared": .bool(context.cleared),
                "reconciled": .bool(context.reconciled),
                "is_parent": .bool(context.isParent),
                "is_child": .bool(context.isChild),
                "balance": .number(Double(context.balance)),
            ],
            balanceOfPrefetch: context.balanceOfPrefetch,
            today: dateString(Date())
        )
    }

    private static func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func dateValue(_ value: String) -> Date? {
        dateFormatter.date(from: value)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}
