import Foundation

struct ScheduleRuleEditability: Hashable, Sendable {
    let hasValidLink: Bool
    let canEditAccount: Bool
    let canEditPayee: Bool
    let canEditAmount: Bool
    let canEditDate: Bool
}

enum ScheduleRuleMutationError: Error, Equatable, Sendable {
    case malformedConditions
    case malformedActions
    case invalidDefinition
    case unsupportedField(String)
    case invalidScheduleLink
}

enum ScheduleRuleMutation {
    static func editability(
        scheduleID: String,
        conditionsJSON: String?,
        actionsJSON: String?
    ) -> ScheduleRuleEditability {
        let conditions = decodeArray(conditionsJSON)
        let actions = decodeArray(actionsJSON)
        let linkActions = actions?.filter { object in
            object.string("op") == "link-schedule"
        } ?? []
        let hasValidLink = linkActions.count == 1
            && linkActions[0].string("value") == scheduleID
        let conditionObjects = conditions?.compactMap(\.objectValue) ?? []
        let account = conditionObjects.filter {
            ["account", "acct"].contains($0.string("field") ?? "")
        }
        let payee = conditionObjects.filter {
            ["payee", "description"].contains($0.string("field") ?? "")
        }
        let amount = conditionObjects.filter { $0.string("field") == "amount" }
        let date = conditionObjects.filter { $0.string("field") == "date" }
        let dateRule = date.count == 1
            ? date[0]["value"].map { value in
                ScheduleRuleProjection.dateRule(
                    from: RuleCondition(field: "date", operation: date[0].string("op") ?? "", value: value)
                )
            } ?? .unavailable
            : .unavailable
        return ScheduleRuleEditability(
            hasValidLink: hasValidLink,
            canEditAccount: account.count == 1
                && account[0].string("op") == "is"
                && account[0].string("value") != nil,
            canEditPayee: payee.count <= 1
                && (payee.isEmpty || (payee[0].string("op") == "is" && payee[0].string("value") != nil)),
            canEditAmount: amount.count == 1 && validAmount(amount[0]),
            canEditDate: date.count == 1
                && ["is", "isapprox"].contains(date[0].string("op") ?? "")
                && dateRule != .unavailable
        )
    }

    static func merge(
        conditionsJSON: String,
        actionsJSON: String,
        scheduleID: String,
        edits: ScheduleEditFields
    ) throws -> (conditions: String?, actions: String?) {
        guard edits.changesDefinition else {
            guard let linkActions = decodeArray(actionsJSON) else {
                throw ScheduleRuleMutationError.malformedActions
            }
            guard linkActions.filter({ $0.string("op") == "link-schedule" }).count == 1,
                  linkActions.first(where: { $0.string("op") == "link-schedule" })?.string("value") == scheduleID else {
                throw ScheduleRuleMutationError.invalidScheduleLink
            }
            return (nil, nil)
        }
        guard var conditions = decodeArray(conditionsJSON) else {
            throw ScheduleRuleMutationError.malformedConditions
        }
        guard var actions = decodeArray(actionsJSON) else {
            throw ScheduleRuleMutationError.malformedActions
        }
        let links = actions.filter { $0.string("op") == "link-schedule" }
        guard links.count == 1, links[0].string("value") == scheduleID else {
            throw ScheduleRuleMutationError.invalidScheduleLink
        }

        let originalConditions = conditions
        let originalActions = actions
        try replace(
            in: &conditions,
            fieldNames: ["account", "acct"],
            change: edits.accountID,
            newField: "account",
            permittedOperations: ["is"]
        )
        try replace(
            in: &conditions,
            fieldNames: ["payee", "description"],
            change: edits.payeeMappingID,
            newField: "description",
            permittedOperations: ["is"]
        )
        if edits.amount != .unchanged {
            guard case .set(let amount?) = edits.amount else {
                throw ScheduleRuleMutationError.invalidDefinition
            }
            let (operation, value) = try amountValue(amount)
            try replaceAmount(
                in: &conditions,
                operation: operation,
                value: value
            )
        }
        if edits.dateRule != .unchanged {
            guard case .set(let dateRule?) = edits.dateRule else {
                throw ScheduleRuleMutationError.invalidDefinition
            }
            let (operation, value) = try dateValue(dateRule)
            try replaceDate(in: &conditions, operation: operation, value: value)
        }

        if edits.changesDefinition,
           let amountCondition = conditions.first(where: {
               ["is", "isapprox", "isbetween"].contains($0.string("op") ?? "")
                   && $0.string("field") == "amount"
           }),
           let amount = postingAmountValue(from: amountCondition.objectValue?["value"]) {
            actions = actions.map { action in
                guard action.string("op") == "set",
                      action.string("field") == "amount",
                       !action.hasTruthyFormulaOrTemplate else { return action }
                var updated = action
                updated.set("value", to: amount)
                return updated
            }
        }

        let conditionData = conditions == originalConditions ? nil : try encode(conditions)
        let actionData = actions == originalActions ? nil : try encode(actions)
        return (conditionData, actionData)
    }

    static func newRuleJSON(
        scheduleID: String,
        definition: ScheduleDefinitionDraft
    ) throws -> (conditions: String, actions: String) {
        var conditions: [RuleJSONValue] = [
            condition(field: "account", operation: "is", value: .string(definition.accountID))
        ]
        if let payeeID = definition.payeeMappingID {
            conditions.append(condition(field: "description", operation: "is", value: .string(payeeID)))
        }
        let (amountOperation, amount) = try amountValue(definition.amount)
        conditions.append(condition(field: "amount", operation: amountOperation, value: amount))
        let (dateOperation, date) = try dateValue(definition.dateRule)
        guard dateOperation == "is" || dateOperation == "isapprox" else {
            throw ScheduleRuleMutationError.invalidDefinition
        }
        conditions.append(condition(field: "date", operation: dateOperation, value: date))
        let actions = [condition(field: "", operation: "link-schedule", value: .string(scheduleID), isAction: true)]
        return (try encode(conditions), try encode(actions))
    }

    static func initialNextDate(for rule: ScheduleDateRule, asOf dayID: String) throws -> String? {
        switch rule {
        case .oneTime(let dayID, _): return dayID
        case .recurring(let recurrence, _):
            return try recurrence.nextOccurrence(onOrAfter: dayID)
        case .unavailable:
            throw ScheduleRuleMutationError.invalidDefinition
        }
    }

    static func nextDateAfterSkip(
        recurrence: ActualScheduleRecurrence,
        currentDayID: String
    ) throws -> String? {
        guard let currentDate = ActualScheduleRecurrence.date(from: currentDayID) else {
            throw ScheduleRuleMutationError.invalidDefinition
        }
        var start = currentDate
        if recurrence.skipWeekend, recurrence.weekendAdjustment == .before {
            let weekday = Calendar.actualScheduleGregorian.component(.weekday, from: currentDate)
            if weekday == 6 || weekday == 7 || weekday == 1 {
                let offset = weekday == 6 ? 3 : weekday == 7 ? 2 : 1
                guard let monday = Calendar.actualScheduleGregorian.date(byAdding: .day, value: offset, to: currentDate) else {
                    throw ScheduleRuleMutationError.invalidDefinition
                }
                start = monday
            }
        }
        guard let dayAfter = Calendar.actualScheduleGregorian.date(byAdding: .day, value: 1, to: start) else {
            throw ScheduleRuleMutationError.invalidDefinition
        }
        return try recurrence.nextOccurrence(onOrAfter: ActualScheduleRecurrence.dayID(from: dayAfter))
    }

    static func updateNextDate(
        for rule: ScheduleDateRule,
        asOf dayID: String,
        currentEffectiveDate: String?
    ) throws -> String? {
        let next = try initialNextDate(for: rule, asOf: dayID)
        guard let next, next != currentEffectiveDate else { return nil }
        return next
    }

    private static func replace(
        in conditions: inout [RuleJSONValue],
        fieldNames: Set<String>,
        change: ScheduleOptionalChange<String>,
        newField: String,
        permittedOperations: Set<String>
    ) throws {
        guard change != .unchanged else { return }
        guard case .set(let value) = change else { return }
        let matches = conditions.indices.filter { index in
            guard let object = conditions[index].objectValue else { return false }
            return fieldNames.contains(object.string("field") ?? "")
                && permittedOperations.contains(object.string("op") ?? "")
        }
        guard matches.count <= 1 else { throw ScheduleRuleMutationError.unsupportedField(newField) }
        if let index = matches.first, value == nil {
            conditions.remove(at: index)
        } else if let index = matches.first, let value {
            var updated = conditions[index]
            updated.set("field", to: .string(newField))
            updated.set("value", to: .string(value))
            conditions[index] = updated
        } else if let value {
            conditions.append(condition(field: newField, operation: "is", value: .string(value)))
        }
    }

    private static func replaceAmount(
        in conditions: inout [RuleJSONValue],
        operation: String,
        value: RuleJSONValue
    ) throws {
        let indices = conditions.indices.filter {
            conditions[$0].string("field") == "amount"
        }
        guard indices.count == 1, let index = indices.first else {
            throw ScheduleRuleMutationError.unsupportedField("amount")
        }
        conditions[index].set("op", to: .string(operation))
        conditions[index].set(
            "value",
            to: preservingUnknownObjectKeys(
                from: conditions[index].objectValue?["value"],
                replacingWith: value,
                knownKeys: ["num1", "num2"]
            )
        )
    }

    private static func replaceDate(
        in conditions: inout [RuleJSONValue],
        operation: String,
        value: RuleJSONValue
    ) throws {
        let indices = conditions.indices.filter { index in
            guard let object = conditions[index].objectValue else { return false }
            return object.string("field") == "date" && ["is", "isapprox"].contains(object.string("op") ?? "")
        }
        guard indices.count == 1, let index = indices.first else {
            throw ScheduleRuleMutationError.unsupportedField("date")
        }
        conditions[index].set("op", to: .string(operation))
        conditions[index].set(
            "value",
            to: preservingUnknownObjectKeys(
                from: conditions[index].objectValue?["value"],
                replacingWith: value,
                knownKeys: [
                    "start", "frequency", "interval", "patterns", "skipWeekend", "weekendSolveMode",
                    "endMode", "endOccurrences", "endDate"
                ]
            )
        )
    }

    private static func preservingUnknownObjectKeys(
        from oldValue: RuleJSONValue?,
        replacingWith newValue: RuleJSONValue,
        knownKeys: Set<String>
    ) -> RuleJSONValue {
        guard case .object(let oldObject)? = oldValue,
              case .object(let newObject) = newValue else { return newValue }
        var merged = oldObject.filter { !knownKeys.contains($0.key) }
        merged.merge(newObject) { _, new in new }
        return .object(merged)
    }

    private static func amountValue(_ amount: ScheduleAmountDraft) throws -> (String, RuleJSONValue) {
        switch amount {
        case .exact(let value):
            guard Int(exactly: Double(value)) == value else { throw ScheduleRuleMutationError.invalidDefinition }
            return ("is", .number(Double(value)))
        case .approximate(let value):
            guard Int(exactly: Double(value)) == value else { throw ScheduleRuleMutationError.invalidDefinition }
            return ("isapprox", .number(Double(value)))
        case .range(let lower, let upper):
            guard lower <= upper,
                  Int(exactly: Double(lower)) == lower, Int(exactly: Double(upper)) == upper else {
                throw ScheduleRuleMutationError.invalidDefinition
            }
            return ("isbetween", .object(["num1": .number(Double(lower)), "num2": .number(Double(upper))]))
        }
    }

    private static func postingAmountValue(from value: RuleJSONValue?) -> RuleJSONValue? {
        guard let value else { return nil }
        if case .object(let range) = value,
           let lower = range["num1"]?.number,
           let upper = range["num2"]?.number {
            return roundedNumber((lower + upper) / 2)
        }
        return value.number.flatMap(roundedNumber)
    }

    private static func roundedNumber(_ value: Double) -> RuleJSONValue? {
        guard value.isFinite else { return nil }
        let rounded = floor(value + 0.5)
        guard let integer = Int(exactly: rounded) else { return nil }
        return .number(Double(integer))
    }

    private static func dateValue(_ rule: ScheduleDateRule) throws -> (String, RuleJSONValue) {
        switch rule {
        case .oneTime(let dayID, let operation):
            guard ActualScheduleRecurrence.date(from: dayID) != nil,
                  ["is", "isapprox"].contains(operation) else {
                throw ScheduleRuleMutationError.invalidDefinition
            }
            return (operation, .string(dayID))
        case .recurring(let recurrence, let operation):
            guard ["is", "isapprox"].contains(operation) else {
                throw ScheduleRuleMutationError.invalidDefinition
            }
            var config: [String: RuleJSONValue] = [
                "start": .string(recurrence.startDayID),
                "frequency": .string(recurrence.frequency)
            ]
            if recurrence.interval != 1 { config["interval"] = .number(Double(recurrence.interval)) }
            if !recurrence.patterns.isEmpty {
                config["patterns"] = .array(recurrence.patterns.map { pattern in
                    switch pattern {
                    case .dayOfMonth(let day): .object(["type": .string("day"), "value": .number(Double(day))])
                    case .weekday(let weekday, let ordinal): .object([
                        "type": .string(weekday.rawValue), "value": .number(Double(ordinal))
                    ])
                    }
                })
            }
            if recurrence.skipWeekend {
                config["skipWeekend"] = .bool(true)
                config["weekendSolveMode"] = .string(recurrence.weekendAdjustment.rawValue)
            }
            switch recurrence.ending {
            case .never: break
            case .afterOccurrences(let count):
                config["endMode"] = .string("after_n_occurrences")
                config["endOccurrences"] = .number(Double(count))
            case .onDate(let dayID):
                config["endMode"] = .string("on_date")
                config["endDate"] = .string(dayID)
            }
            return (operation, .object(config))
        case .unavailable:
            throw ScheduleRuleMutationError.invalidDefinition
        }
    }

    private static func validAmount(_ condition: [String: RuleJSONValue]) -> Bool {
        guard let value = condition["value"] else { return false }
        switch condition.string("op") {
        case "is", "isapprox": return value.number?.isFinite == true
        case "isbetween":
            guard let range = value.objectValue,
                  let lower = range["num1"]?.number,
                  let upper = range["num2"]?.number else { return false }
            return lower.isFinite && upper.isFinite && lower <= upper
        default: return false
        }
    }

    private static func condition(
        field: String,
        operation: String,
        value: RuleJSONValue,
        isAction: Bool = false
    ) -> RuleJSONValue {
        .object(isAction
            ? ["op": .string(operation), "value": value]
            : ["op": .string(operation), "field": .string(field), "value": value])
    }

    private static func decodeArray(_ json: String?) -> [RuleJSONValue]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([RuleJSONValue].self, from: data)
    }

    private static func encode(_ values: [RuleJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: try encoder.encode(values), encoding: .utf8) ?? "[]"
    }
}

private extension RuleJSONValue {
    var objectValue: [String: RuleJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    func string(_ key: String) -> String? {
        guard case .string(let value)? = objectValue?[key] else { return nil }
        return value
    }

    var hasTruthyFormulaOrTemplate: Bool {
        guard let options = objectValue?["options"]?.objectValue else { return false }
        return options["formula"].map(\.isJavaScriptTruthy) == true
            || options["template"].map(\.isJavaScriptTruthy) == true
    }

    var isJavaScriptTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0 && !value.isNaN
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }

    mutating func set(_ key: String, to value: RuleJSONValue) {
        guard case .object(var object) = self else { return }
        object[key] = value
        self = .object(object)
    }
}

private extension Dictionary where Key == String, Value == RuleJSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}
