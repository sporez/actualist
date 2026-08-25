import Foundation

/// Pure, stateless owner of payee-rule editor draft interpretation and payload
/// normalization.
///
/// This type holds no `AppState`, repository, or SwiftUI dependency and exists so
/// the rule-editor views can render layout and bind controls while a single,
/// testable seam decides Actual-compatible `RuleCondition`/`RuleAction` field,
/// type, operation, and value shapes.
///
/// It owns:
/// - the default `RuleJSONValue` for each `RuleCondition.ValueKind`;
/// - value-shape normalization when a condition's operation changes
///   (``valueForChangedOperation(currentValue:operation:field:)``);
/// - field-change re-derivation for `RuleCondition`
///   (``condition(afterFieldChange:from:)``);
/// - operation-change and field-change re-derivation for `RuleAction`;
/// - amount text <-> Actual minor-units parse/format;
/// - range `num1`/`num2` get/set for `isbetween` values;
/// - multi-value array add/remove and payee selection.
///
/// Behavior intentionally mirrors the inline logic previously embedded in the
/// rule-editor SwiftUI views; the views now call these functions and assign the
/// result rather than interpreting payload values in binding setters.
enum RuleEditorDraftState {
    // MARK: Default value for a value kind

    /// The default `RuleJSONValue` a freshly-changed field/operation should hold.
    /// `date` uses the shared gregorian `yyyy-MM-dd` formatter so a new date
    /// condition round-trips through Actual's strict date parser.
    static func defaultValue(for kind: RuleCondition.ValueKind?) -> RuleJSONValue {
        switch kind {
        case .boolean: .bool(false)
        case .number: .number(0)
        case .date: .string(sharedDateFormatter.string(from: Date()))
        case .string: .string("")
        case .id, nil: .null
        }
    }

    // MARK: Condition — operation change

    /// Returns the value a condition should hold after its operation changes.
    ///
    /// Branch order mirrors the original editor normalization so a value already
    /// shaped for the new operation is preserved where the operation accepts it:
    /// `onBudget`/`offBudget` collapse to `null`; `oneOf`/`notOneOf` need an
    /// array (wrapping a single value, or an empty array from `null`);
    /// `isbetween` needs a `{"num1","num2"}` object; an array under a scalar
    /// operation collapses to its first element. The final fallthrough returns
    /// the value unchanged.
    static func valueForChangedOperation(
        currentValue: RuleJSONValue,
        operation: String,
        field: String
    ) -> RuleJSONValue {
        if operation == "onBudget" || operation == "offBudget" {
            return .null
        }
        if operation == "oneOf" || operation == "notOneOf" {
            if case .array = currentValue { return currentValue }
            return currentValue == .null ? .array([]) : .array([currentValue])
        }
        if case .array(let values) = currentValue {
            return values.first ?? defaultValue(for: RuleCondition.valueKind(for: field))
        }
        if operation == "isbetween" {
            let initial = currentValue.isNumberLike ? currentValue : .number(0)
            return .object(["num1": initial, "num2": initial])
        }
        if case .object(let range) = currentValue {
            return range["num1"] ?? .number(0)
        }
        return currentValue
    }

    // MARK: Condition — field change

    /// Returns a condition updated for a changed editor field, re-deriving
    /// `field`/`type`/`options` always, and `operation`/`value` only when the
    /// field actually changed (or when the current operation is not valid for
    /// the new field). Mirrors the original editor field binding.
    static func condition(
        afterFieldChange newField: String,
        from condition: RuleCondition
    ) -> RuleCondition {
        var updated = condition
        let previousField = condition.editorField
        let newKind = RuleCondition.valueKind(for: newField)
        updated.field = RuleCondition.serializedField(newField)
        updated.options = RuleCondition.options(for: newField)
        updated.type = newKind?.rawValue
        if previousField != newField {
            updated.operation = RuleCondition.operations(for: newField).first ?? "is"
            updated.value = defaultValue(for: newKind)
        } else if !RuleCondition.operations(for: newField).contains(condition.operation) {
            updated.operation = RuleCondition.operations(for: newField).first ?? "is"
        }
        return updated
    }

    // MARK: Action — operation change

    /// Returns an action updated for a changed operation, fully transitioning it
    /// to `operation`: `set` initializes a default category target when no field
    /// is set; `prepend-notes` and `append-notes` clear the field, target a
    /// string value, and seed an empty string when the current value is not
    /// already a string. The operation is set from the parameter so the function
    /// is self-contained whether called before or after a binding applies the new
    /// operation.
    static func action(
        afterOperationChange operation: String,
        from action: RuleAction
    ) -> RuleAction {
        var updated = action
        updated.operation = operation
        if operation == "set" {
            if updated.field == nil {
                updated.field = "category"
                updated.type = RuleCondition.ValueKind.id.rawValue
                updated.value = .null
            }
        } else if operation == "set-split-amount" {
            updated.field = nil
            updated.type = RuleCondition.ValueKind.number.rawValue
            updated.value = updated.value.isNumberLike ? updated.value : .number(0)
            updated.options = [
                "method": .string(updated.splitMethod ?? "fixed-amount"),
                "splitIndex": .number(Double(updated.splitIndex ?? 0))
            ]
        } else {
            let needsStringValue: Bool
            if case .string = updated.value {
                needsStringValue = false
            } else {
                needsStringValue = true
            }
            updated.field = nil
            updated.type = RuleCondition.ValueKind.string.rawValue
            if needsStringValue {
                updated.value = .string("")
            }
        }
        return updated
    }

    // MARK: Action — field change

    /// Returns an action updated for a changed set-target field, or `nil` when
    /// the editor field is unchanged (the original binding guarded against this
    /// to avoid wiping an existing value when the display field is re-selected,
    /// e.g. `"payee"` over an underlying `"description"` field).
    static func action(
        _ action: RuleAction,
        settingSplitMethod method: String
    ) -> RuleAction {
        var updated = action
        var options = updated.options ?? [:]
        options["method"] = .string(method)
        if options["splitIndex"] == nil {
            options["splitIndex"] = .number(0)
        }
        updated.options = options
        if method == "remainder" {
            updated.value = .number(0)
        }
        return updated
    }

    static func action(
        _ action: RuleAction,
        settingSplitIndex index: Int?
    ) -> RuleAction {
        var updated = action
        var options = updated.options ?? [:]
        if let index {
            options["splitIndex"] = .number(Double(max(0, index)))
        } else {
            options.removeValue(forKey: "splitIndex")
        }
        if action.operation == "set-split-amount" {
            if options["method"] == nil {
                options["method"] = .string("fixed-amount")
            }
            if options["splitIndex"] == nil {
                options["splitIndex"] = .number(0)
            }
        }
        updated.options = options.isEmpty ? nil : options
        return updated
    }

    static func action(
        afterFieldChange newField: String,
        from action: RuleAction
    ) -> RuleAction? {
        guard action.editorField != newField else { return nil }
        var updated = action
        let kind = RuleCondition.valueKind(for: newField)
        updated.field = RuleCondition.serializedField(newField)
        updated.type = kind?.rawValue
        updated.value = defaultValue(for: kind)
        return updated
    }

    // MARK: Amount text <-> minor units

    /// The Actual minor-units `Double` carried by an amount value, whether stored
    /// as `.number` or a numeric `.string`. Returns `nil` for non-numeric shapes.
    static func minorUnits(in raw: RuleJSONValue) -> Double? {
        switch raw {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }

    /// Editable display text for an amount value, in budget display units with
    /// no currency symbol (suitable for a `TextField`).
    static func amountDisplayText(
        _ raw: RuleJSONValue,
        currency: BudgetCurrency = .usd
    ) -> String {
        guard let number = minorUnits(in: raw) else { return "" }
        return editableAmount(currency.displayUnits(fromMinorUnits: Int(number.rounded())))
    }

    /// Parses typed display units into the Actual minor-units value to store.
    /// Invalid or empty input becomes `.number(0)`, matching the original editor.
    static func amountValue(
        from text: String,
        currency: BudgetCurrency = .usd
    ) -> RuleJSONValue {
        guard let decimal = Decimal(string: text),
              let minorUnits = currency.minorUnits(fromDisplay: decimal) else {
            return .number(0)
        }
        return .number(Double(minorUnits))
    }

    /// Editable display text for a non-amount scalar value. Numbers are shown
    /// without currency conversion; `null`/`bool`/`array`/`object` render empty.
    static func editableString(_ raw: RuleJSONValue) -> String {
        switch raw {
        case .string(let text): text
        case .number(let number): editableAmount(number)
        case .null: ""
        case .bool, .array, .object: ""
        }
    }

    // MARK: Range (isbetween) get/set

    /// Display text for one bound of an `isbetween` range object.
    static func rangeDisplayText(
        _ raw: RuleJSONValue,
        key: String,
        currency: BudgetCurrency = .usd
    ) -> String {
        guard case .object(let range) = raw, let cell = range[key] else { return "" }
        return amountDisplayText(cell, currency: currency)
    }

    /// Sets one bound of an `isbetween` range object, creating the object when
    /// the current value is not already a range.
    static func rangeValue(
        from text: String,
        current: RuleJSONValue,
        key: String,
        currency: BudgetCurrency = .usd
    ) -> RuleJSONValue {
        var range: [String: RuleJSONValue]
        if case .object(let existing) = current {
            range = existing
        } else {
            range = [:]
        }
        range[key] = amountValue(from: text, currency: currency)
        return .object(range)
    }

    // MARK: Multi-value (oneOf / notOneOf)

    /// The string identifiers stored in a multi-value array, ignoring non-string
    /// entries defensively.
    static func selectedIDs(_ raw: RuleJSONValue) -> [String] {
        guard case .array(let values) = raw else { return [] }
        return values.compactMap { item in
            if case .string(let id) = item { return id }
            return nil
        }
    }

    /// The free-text strings stored in a multi-value array, ignoring non-string
    /// entries defensively.
    static func stringValues(_ raw: RuleJSONValue) -> [String] {
        guard case .array(let values) = raw else { return [] }
        return values.compactMap { item in
            if case .string(let text) = item { return text }
            return nil
        }
    }

    /// Appends an identifier to a multi-value array, returning the input
    /// unchanged when the identifier is already present.
    static func appendID(_ id: String, to raw: RuleJSONValue) -> RuleJSONValue {
        var ids = selectedIDs(raw)
        guard !ids.contains(id) else { return raw }
        ids.append(id)
        return .array(ids.map(RuleJSONValue.string))
    }

    /// Removes an identifier from a multi-value array.
    static func removeID(_ id: String, from raw: RuleJSONValue) -> RuleJSONValue {
        var ids = selectedIDs(raw)
        ids.removeAll { $0 == id }
        return .array(ids.map(RuleJSONValue.string))
    }

    /// Appends an empty free-text entry to a multi-value string array.
    static func appendStringValue(to raw: RuleJSONValue) -> RuleJSONValue {
        var values = stringValues(raw)
        values.append("")
        return .array(values.map(RuleJSONValue.string))
    }

    /// Removes a free-text entry from a multi-value string array by index, a
    /// no-op when the index is out of bounds.
    static func removeStringValue(at index: Int, from raw: RuleJSONValue) -> RuleJSONValue {
        var values = stringValues(raw)
        guard values.indices.contains(index) else { return raw }
        values.remove(at: index)
        return .array(values.map(RuleJSONValue.string))
    }

    /// Updates a payee-bound value after a payee pick: toggling membership for
    /// multi-value operations, or replacing the value for single-value
    /// operations.
    static func payeeValue(
        afterSelecting id: String,
        current: RuleJSONValue,
        isMultiValue: Bool
    ) -> RuleJSONValue {
        if isMultiValue {
            return selectedIDs(current).contains(id)
                ? removeID(id, from: current)
                : appendID(id, to: current)
        }
        return .string(id)
    }

    // MARK: Shared formatter

    /// Gregorian `yyyy-MM-dd` formatter used to produce default date values.
    ///
    /// This consolidates the two byte-identical private formatters previously
    /// duplicated across `RuleConditionEditor` and `RuleActionEditor`.
    /// `RuleRepository.ruleDateFormatter` is kept separate because it performs
    /// strict (`isLenient == false`) *parsing* for validation, whereas this
    /// formatter performs only `Date -> String` *formatting* (unaffected by
    /// leniency); the two concerns are not genuinely identical.
    static let sharedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Renders a `Double` as an editable numeric string: an integer when the value
    /// is integral and in `Int` range, otherwise its full `Double` representation.
    static func editableAmount(_ number: Double) -> String {
        guard number.isFinite else { return "" }
        if number.rounded() == number,
           number >= Double(Int.min),
           number <= Double(Int.max) {
            return String(Int(number))
        }
        return String(number)
    }
}
