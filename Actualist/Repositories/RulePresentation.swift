import Foundation

enum RulePresentation {
    static func presentationField(_ field: String) -> String {
        switch field {
        case "description": "payee"
        case "acct": "account"
        case "imported_description": "imported_payee"
        default: field
        }
    }

    static func fieldName(_ field: String) -> String {
        let editorField = presentationField(field)
        return RuleCondition.editableFields.first { $0.value == editorField }?.name ?? "Unsupported field"
    }

    static func operationName(_ operation: String) -> String {
        switch operation {
        case "is": "Is"
        case "isNot": "Is not"
        case "oneOf": "Is one of"
        case "notOneOf": "Is not one of"
        case "contains": "Contains"
        case "doesNotContain": "Does not contain"
        case "matches": "Matches"
        case "isapprox": "Is approximately"
        case "isbetween": "Is between"
        case "gt": "Is greater than"
        case "gte": "Is at least"
        case "lt": "Is less than"
        case "lte": "Is at most"
        case "hasTags": "Has all tags"
        case "hasAnyTag": "Has any tag"
        case "onBudget": "Is on budget"
        case "offBudget": "Is off budget"
        default: "Uses an unsupported comparison"
        }
    }

    static func actionName(_ operation: String) -> String {
        switch operation {
        case "set": "Set"
        case "prepend-notes": "Prepend notes with"
        case "append-notes": "Append notes with"
        case "link-schedule": "Link to schedule"
        default: "Unsupported action"
        }
    }

    static func valueText(
        _ value: RuleJSONValue,
        field: String?,
        options: RuleEditorOptions?
    ) -> String {
        guard let field else {
            return plainValueText(value)
        }

        let normalizedField = presentationField(field)

        switch RuleCondition.valueKind(for: normalizedField) {
        case .id:
            return identifierValueText(value, field: normalizedField, options: options)
        case .number:
            return amountValueText(value)
        case .boolean:
            if case .bool(let enabled) = value { return enabled ? "Yes" : "No" }
            return value == .null ? "None" : "Unsupported value"
        case .date:
            return dateValueText(value)
        case .string:
            return plainValueText(value)
        case nil:
            return "Unsupported value"
        }
    }

    static func deletedValueName(for field: String) -> String {
        "Deleted \(fieldName(field).lowercased())"
    }

    private static func identifierValueText(
        _ value: RuleJSONValue,
        field: String,
        options: RuleEditorOptions?
    ) -> String {
        switch value {
        case .null:
            return "None"
        case .string(let id):
            return identifierName(for: id, field: field, options: options)
        case .array(let values):
            let names = values.map { item -> String in
                guard case .string(let id) = item else { return "Unsupported value" }
                return identifierName(for: id, field: field, options: options)
            }
            return names.isEmpty ? "No values" : names.joined(separator: ", ")
        default:
            return "Unsupported value"
        }
    }

    private static func identifierName(
        for id: String,
        field: String,
        options: RuleEditorOptions?
    ) -> String {
        guard !id.isEmpty else { return "None" }
        guard let options else { return "…" }
        let choices: [RuleEditorChoice]
        switch field {
        case "account": choices = options.accounts
        case "category": choices = options.categories
        case "category_group": choices = options.categoryGroups
        case "payee", "description": choices = options.payees
        default: return "Unsupported value"
        }
        return choices.first { $0.id == id }?.name ?? deletedValueName(for: field)
    }

    private static func amountValueText(_ value: RuleJSONValue) -> String {
        switch value {
        case .number(let number):
            return formattedAmount(number)
        case .string(let number):
            guard let amount = Double(number) else { return "Unsupported value" }
            return formattedAmount(amount)
        case .object(let range):
            guard let first = range["num1"], let second = range["num2"] else {
                return "Unsupported value"
            }
            return "\(amountValueText(first)) and \(amountValueText(second))"
        case .null:
            return "None"
        default:
            return "Unsupported value"
        }
    }

    private static func dateValueText(_ value: RuleJSONValue) -> String {
        guard case .object(let recurrence) = value else {
            return plainValueText(value)
        }
        let start = recurrence["start"].map(plainValueText)
        let frequency: String?
        switch recurrence["frequency"] {
        case .some(.string(let value)):
            frequency = value.capitalized
        default:
            frequency = nil
        }
        let text = [frequency.map { "\($0) recurrence" }, start.map { "beginning \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
        return text.isEmpty ? "Recurring date" : text
    }

    private static func plainValueText(_ value: RuleJSONValue) -> String {
        switch value {
        case .null:
            return "None"
        case .bool(let enabled):
            return enabled ? "Yes" : "No"
        case .number(let number):
            guard number.isFinite else { return "Unsupported value" }
            if number.rounded() == number,
               number >= Double(Int.min),
               number <= Double(Int.max) {
                return String(Int(number))
            }
            return String(number)
        case .string(let text):
            return text.isEmpty ? "Empty" : text
        case .array(let values):
            let presented = values.map(plainValueText)
            return presented.isEmpty ? "No values" : presented.joined(separator: ", ")
        case .object:
            return "Unsupported value"
        }
    }

    private static func formattedAmount(_ number: Double) -> String {
        guard number.isFinite,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            return "Unsupported value"
        }
        return Int(number.rounded()).actualMoney.formatted()
    }
}

extension ManagedRule {
    var isScheduleOwned: Bool {
        guard let data = rawActionsJSON.data(using: .utf8),
              let actions = try? JSONDecoder().decode([RuleAction].self, from: data) else {
            return false
        }
        return actions.contains { $0.operation == "link-schedule" }
    }

    func summary(options: RuleEditorOptions?) -> String {
        guard let draft else { return readOnlySummary(options: options) }
        let conditions = draft.conditions.map { condition in
            var parts = [
                RulePresentation.fieldName(condition.editorField).lowercased(),
                RulePresentation.operationName(condition.operation).lowercased()
            ]
            if condition.operation != "onBudget" && condition.operation != "offBudget" {
                parts.append(RulePresentation.valueText(condition.value, field: condition.field, options: options))
            }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
            .joined(separator: draft.conditionsJoin == .and ? " and " : " or ")
        let actions = draft.actions.map { action in
            [
                RulePresentation.actionName(action.operation).lowercased(),
                action.editorField.map { RulePresentation.fieldName($0).lowercased() },
                RulePresentation.valueText(action.value, field: action.editorField, options: options)
            ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }.joined(separator: ", ")
        return "If \(conditions), then \(actions)"
    }

    private func readOnlySummary(options: RuleEditorOptions?) -> String {
        let decoder = JSONDecoder()
        guard let conditionData = rawConditionsJSON.data(using: .utf8),
              let actionData = rawActionsJSON.data(using: .utf8),
              let conditions = try? decoder.decode([RuleCondition].self, from: conditionData),
              let actions = try? decoder.decode([RuleAction].self, from: actionData) else {
            return "Unsupported rule"
        }
        let conditionText = conditions.map { readOnlyConditionText($0, options: options) }
            .joined(separator: " and ")
        let actionText = actions.map { readOnlyActionText($0, options: options) }
            .joined(separator: ", ")
        guard !conditionText.isEmpty, !actionText.isEmpty else { return "Unsupported rule" }
        return "If \(conditionText), then \(actionText)"
    }

    func readOnlyDetails(options: RuleEditorOptions?) -> [String] {
        let decoder = JSONDecoder()
        var details: [String] = []

        if let data = rawConditionsJSON.data(using: .utf8),
           let conditions = try? decoder.decode([RuleCondition].self, from: data) {
            details += conditions.map {
                "Condition: " + capitalizingFirst(readOnlyConditionText($0, options: options))
            }
        } else {
            details.append("Unsupported conditions")
        }

        if let data = rawActionsJSON.data(using: .utf8),
           let actions = try? decoder.decode([RuleAction].self, from: data) {
            details += actions.map { action in
                if action.operation == "link-schedule" { return "Action: Link to schedule" }
                guard ["set", "prepend-notes", "append-notes"].contains(action.operation) else {
                    return "Unsupported action"
                }
                let field = action.editorField.map(RulePresentation.presentationField)
                return [
                    "Action: \(RulePresentation.actionName(action.operation))",
                    field.map(RulePresentation.fieldName),
                    RulePresentation.valueText(action.value, field: field, options: options)
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
        } else {
            details.append("Unsupported actions")
        }

        return details.isEmpty ? ["Unsupported rule details"] : details
    }

    private func readOnlyConditionText(_ condition: RuleCondition, options: RuleEditorOptions?) -> String {
        let field = RulePresentation.presentationField(condition.field)
        guard RuleCondition.valueKind(for: field) != nil else { return "Unsupported condition" }
        var parts = [
            RulePresentation.fieldName(field).lowercased(),
            RulePresentation.operationName(condition.operation).lowercased()
        ]
        if condition.operation != "onBudget" && condition.operation != "offBudget" {
            parts.append(RulePresentation.valueText(condition.value, field: field, options: options))
        }
        return parts.joined(separator: " ")
    }

    private func readOnlyActionText(_ action: RuleAction, options: RuleEditorOptions?) -> String {
        if action.operation == "link-schedule" { return "link to schedule" }
        guard ["set", "prepend-notes", "append-notes"].contains(action.operation) else {
            return "Unsupported action"
        }
        let field = action.editorField.map(RulePresentation.presentationField)
        return [
            RulePresentation.actionName(action.operation).lowercased(),
            field.map { RulePresentation.fieldName($0).lowercased() },
            RulePresentation.valueText(action.value, field: field, options: options)
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func capitalizingFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + String(text.dropFirst())
    }
}
