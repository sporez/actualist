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
/// - native amount values <-> Actual minor-units conversion;
/// - range `num1`/`num2` get/set for `isbetween` values;
/// - exact Actual day ids <-> native calendar selections;
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
        case .date: dateValue(from: Date())
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

    // MARK: Native amount values <-> minor units

    /// The Actual minor-units `Double` carried by an amount value, whether stored
    /// as `.number` or a numeric `.string`. Returns `nil` for non-numeric shapes.
    static func minorUnits(in raw: RuleJSONValue) -> Double? {
        switch raw {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }

    /// The text an amount field starts from: Actual's `forEdit` of the stored minor units, or
    /// empty for a missing or non-numeric value.
    static func amountEditText(_ raw: RuleJSONValue, currency: BudgetCurrency = .usd) -> String {
        guard let number = minorUnits(in: raw),
              let minorUnits = Int(exactly: number.rounded()) else {
            return ""
        }
        return BudgetMoneyInputFormat.editText(minorUnits: minorUnits, currency: currency)
    }

    /// The value an amount field commits, read the way Actual's `AmountInput` does (`fromEdit`).
    /// Blank text clears the value (`.null`, which keeps the rule unsavable). Unreadable text
    /// returns `nil` so the caller keeps the current value.
    static func amountValue(fromText text: String, currency: BudgetCurrency = .usd) -> RuleJSONValue? {
        switch BudgetMoneyInputFormat.minorUnits(text, currency: currency) {
        case .success(let minorUnits): .number(Double(minorUnits))
        case .failure(.empty): .null
        case .failure: nil
        }
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

    /// The starting text for one bound of an `isbetween` range object.
    static func rangeEditText(
        _ raw: RuleJSONValue,
        key: String,
        currency: BudgetCurrency = .usd
    ) -> String {
        guard case .object(let range) = raw, let cell = range[key] else { return "" }
        return amountEditText(cell, currency: currency)
    }

    /// Sets one bound of an `isbetween` range object from committed text, creating the object when
    /// the current value is not already a range. `nil` when the text is unreadable.
    static func rangeValue(
        fromText text: String,
        current: RuleJSONValue,
        key: String,
        currency: BudgetCurrency = .usd
    ) -> RuleJSONValue? {
        guard let amount = amountValue(fromText: text, currency: currency) else { return nil }
        var range: [String: RuleJSONValue]
        if case .object(let existing) = current {
            range = existing
        } else {
            range = [:]
        }
        range[key] = amount
        return .object(range)
    }

    /// The amount field named `key` (`"value"` for a plain amount, else a range bound): its starting text.
    static func amountFieldEditText(key: String, value: RuleJSONValue, currency: BudgetCurrency = .usd) -> String {
        key == amountFieldKey
            ? amountEditText(value, currency: currency)
            : rangeEditText(value, key: key, currency: currency)
    }

    /// The whole value after committing `text` in the amount field named `key`; `nil` when unreadable.
    static func amountFieldValue(
        key: String,
        text: String,
        current: RuleJSONValue,
        currency: BudgetCurrency = .usd
    ) -> RuleJSONValue? {
        key == amountFieldKey
            ? amountValue(fromText: text, currency: currency)
            : rangeValue(fromText: text, current: current, key: key, currency: currency)
    }

    static let amountFieldKey = "value"

    // MARK: Exact date selection

    /// Returns a native calendar selection only for a complete Actual day id.
    /// Year- and month-only `is` conditions stay in their lossless text form.
    static func dateSelection(_ raw: RuleJSONValue) -> Date? {
        guard case .string(let dayID) = raw,
              let date = ActualDateOnly.date(from: dayID, timeZone: .current),
              dateValue(from: date) == raw else {
            return nil
        }
        return date
    }

    /// Stores the calendar day shown by a native date picker as Actual's
    /// `yyyy-MM-dd` string without converting the selection through UTC.
    static func dateValue(from date: Date) -> RuleJSONValue {
        .string(dayID(from: date))
    }

    static func dayID(from date: Date) -> String {
        ActualDateOnly.dayID(from: date, timeZone: .current)
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
