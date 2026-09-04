import Foundation
import Testing
@testable import Actualist

/// Focused tests for `RuleEditorDraftState` covering the pure rule-editor draft
/// logic previously embedded (untested) in SwiftUI binding setters: default
/// values per value kind, condition operation-change value normalization,
/// condition/action field-change re-derivation, action operation-change
/// re-derivation, native amount values <-> Actual minor-units, calendar dates,
/// range get/set, and
/// multi-value array mutation including payee toggle behavior.
struct RuleEditorDraftStateTests {

    // MARK: - defaultValue(for:)

    @Test func defaultValue_booleanIsFalse() {
        #expect(RuleEditorDraftState.defaultValue(for: .boolean) == .bool(false))
    }

    @Test func defaultValue_numberIsZero() {
        #expect(RuleEditorDraftState.defaultValue(for: .number) == .number(0))
    }

    @Test func defaultValue_stringIsEmpty() {
        #expect(RuleEditorDraftState.defaultValue(for: .string) == .string(""))
    }

    @Test func defaultValue_idIsNull() {
        #expect(RuleEditorDraftState.defaultValue(for: .id) == .null)
    }

    @Test func defaultValue_nilKindIsNull() {
        #expect(RuleEditorDraftState.defaultValue(for: nil) == .null)
    }

    @Test func defaultValue_dateIsGregorianDateString() {
        let value = RuleEditorDraftState.defaultValue(for: .date)
        guard case .string(let dateText) = value else {
            Issue.record("expected string date, got \(value)")
            return
        }
        #expect(dateText.count == 10)
        #expect(dateText.filter { $0 == "-" }.count == 2)
        guard let selection = RuleEditorDraftState.dateSelection(value) else {
            Issue.record("expected a valid exact-date selection")
            return
        }
        #expect(RuleEditorDraftState.dateValue(from: selection) == value)
    }

    // MARK: - valueForChangedOperation

    @Test func operationChange_onBudgetCollapsesToNull() {
        #expect(
            RuleEditorDraftState.valueForChangedOperation(
                currentValue: .string("acct-x"), operation: "onBudget", field: "account"
            ) == .null
        )
    }

    @Test func operationChange_offBudgetCollapsesToNull() {
        #expect(
            RuleEditorDraftState.valueForChangedOperation(
                currentValue: .array([.string("a")]), operation: "offBudget", field: "account"
            ) == .null
        )
    }

    @Test func operationChange_oneOfPreservesExistingArray() {
        let current: RuleJSONValue = .array([.string("a"), .string("b")])
        #expect(
            RuleEditorDraftState.valueForChangedOperation(
                currentValue: current, operation: "oneOf", field: "category"
            ) == current
        )
    }

    @Test func operationChange_oneOfWrapsNullAsEmptyArray() {
        #expect(
            RuleEditorDraftState.valueForChangedOperation(
                currentValue: .null, operation: "oneOf", field: "category"
            ) == .array([])
        )
    }

    @Test func operationChange_oneOfWrapsScalarAsSingleElementArray() {
        #expect(
            RuleEditorDraftState.valueForChangedOperation(
                currentValue: .string("a"), operation: "notOneOf", field: "category"
            ) == .array([.string("a")])
        )
    }

    @Test func operationChange_scalarOpCollapsesArrayToFirstElement() {
        let result = RuleEditorDraftState.valueForChangedOperation(
            currentValue: .array([.string("a"), .string("b")]), operation: "is", field: "category"
        )
        #expect(result == .string("a"))
    }

    @Test func operationChange_scalarOpCollapsesEmptyArrayToDefaultForField() {
        // An empty array under a scalar operation has no first element; fall back
        // to the default for the field's value kind (category -> id -> .null).
        let result = RuleEditorDraftState.valueForChangedOperation(
            currentValue: .array([]), operation: "is", field: "category"
        )
        #expect(result == .null)
    }

    @Test func operationChange_isbetweenWithNumberLikeBuildsRangeObject() {
        let result = RuleEditorDraftState.valueForChangedOperation(
            currentValue: .number(1250), operation: "isbetween", field: "amount"
        )
        #expect(result == .object(["num1": .number(1250), "num2": .number(1250)]))
    }

    @Test func operationChange_isbetweenWithNonNumberBuildsZeroRangeObject() {
        let result = RuleEditorDraftState.valueForChangedOperation(
            currentValue: .null, operation: "isbetween", field: "amount"
        )
        #expect(result == .object(["num1": .number(0), "num2": .number(0)]))
    }

    @Test func operationChange_scalarOpUnwrapsRangeObjectToFirstBound() {
        let result = RuleEditorDraftState.valueForChangedOperation(
            currentValue: .object(["num1": .number(1000), "num2": .number(2000)]),
            operation: "is",
            field: "amount"
        )
        #expect(result == .number(1000))
    }

    @Test func operationChange_scalarOpWithRangeMissingFirstBoundFallsBackToZero() {
        let result = RuleEditorDraftState.valueForChangedOperation(
            currentValue: .object(["num2": .number(2000)]), operation: "gt", field: "amount"
        )
        #expect(result == .number(0))
    }

    @Test func operationChange_isWithPlainScalarValuePassesThrough() {
        #expect(
            RuleEditorDraftState.valueForChangedOperation(
                currentValue: .string("groceries"), operation: "is", field: "notes"
            ) == .string("groceries")
        )
    }

    // MARK: - condition(afterFieldChange:from:)

    @Test func conditionFieldChange_differentFieldResetsOperationAndValue() {
        let original = RuleCondition(
            field: "category", operation: "oneOf",
            value: .array([.string("a")]), type: "id"
        )
        let updated = RuleEditorDraftState.condition(afterFieldChange: "amount", from: original)
        #expect(updated.field == "amount")
        #expect(updated.type == RuleCondition.ValueKind.number.rawValue)
        #expect(updated.options == nil)
        #expect(updated.operation == "is")
        #expect(updated.value == .number(0))
    }

    @Test func conditionFieldChange_toPayeeMapsToDescriptionSerializedField() {
        let original = RuleCondition(field: "category", operation: "is", value: .null, type: "id")
        let updated = RuleEditorDraftState.condition(afterFieldChange: "payee", from: original)
        #expect(updated.field == "description")
        #expect(updated.type == RuleCondition.ValueKind.id.rawValue)
        #expect(updated.value == .null)
    }

    @Test func conditionFieldChange_toAmountInflowSetsInflowOption() {
        let original = RuleCondition(field: "category", operation: "is", value: .null, type: "id")
        let updated = RuleEditorDraftState.condition(afterFieldChange: "amount-inflow", from: original)
        #expect(updated.field == "amount")
        #expect(updated.options == ["inflow": .bool(true)])
        #expect(updated.type == RuleCondition.ValueKind.number.rawValue)
        #expect(updated.value == .number(0))
    }

    @Test func conditionFieldChange_sameFieldKeepsOperationAndValue() {
        let original = RuleCondition(
            field: "category", operation: "is", value: .string("cat-x"), type: "id"
        )
        let updated = RuleEditorDraftState.condition(afterFieldChange: "category", from: original)
        #expect(updated.operation == "is")
        #expect(updated.value == .string("cat-x"))
        #expect(updated.type == "id")
    }

    @Test func conditionFieldChange_sameFieldButInvalidOperationResetsOperationOnly() {
        // Construct a condition whose operation is not valid for its field, then
        // re-select the same field: only the operation should reset, value kept.
        let original = RuleCondition(
            field: "notes", operation: "isbetween", value: .string("text"), type: "string"
        )
        let updated = RuleEditorDraftState.condition(afterFieldChange: "notes", from: original)
        #expect(updated.operation == "is")
        #expect(updated.value == .string("text"))
    }

    @Test func conditionFieldChange_toBooleanFieldSetsBoolDefault() {
        let original = RuleCondition(field: "category", operation: "is", value: .null, type: "id")
        let updated = RuleEditorDraftState.condition(afterFieldChange: "cleared", from: original)
        #expect(updated.type == RuleCondition.ValueKind.boolean.rawValue)
        #expect(updated.operation == "is")
        #expect(updated.value == .bool(false))
    }

    // MARK: - action(afterOperationChange:from:)

    @Test func actionOpChange_toSetWithNilFieldInitializesCategoryTarget() {
        let original = RuleAction(operation: "append-notes", value: .string("x"), type: "string")
        let updated = RuleEditorDraftState.action(afterOperationChange: "set", from: original)
        #expect(updated.operation == "set")
        #expect(updated.field == "category")
        #expect(updated.type == RuleCondition.ValueKind.id.rawValue)
        #expect(updated.value == .null)
    }

    @Test func actionOpChange_toSetWithExistingFieldLeavesFieldAlone() {
        let original = RuleAction(operation: "append-notes", field: "account", value: .string("x"), type: "id")
        let updated = RuleEditorDraftState.action(afterOperationChange: "set", from: original)
        #expect(updated.field == "account")
        #expect(updated.type == "id")
        #expect(updated.value == .string("x"))
    }

    @Test func actionOpChange_toPrependNotesClearsFieldAndKeepsStringValue() {
        let original = RuleAction(operation: "set", field: "category", value: .string("note"), type: "id")
        let updated = RuleEditorDraftState.action(afterOperationChange: "prepend-notes", from: original)
        #expect(updated.field == nil)
        #expect(updated.type == RuleCondition.ValueKind.string.rawValue)
        #expect(updated.value == .string("note"))
    }

    @Test func actionOpChange_toDeleteTransactionClearsField() {
        let original = RuleAction(operation: "set", field: "category", value: .string("groceries"), type: "id")
        let updated = RuleEditorDraftState.action(afterOperationChange: "delete-transaction", from: original)
        #expect(updated.operation == "delete-transaction")
        #expect(updated.field == nil)
        #expect(updated.value == .string("groceries") || updated.value == .string(""))
    }

    @Test func actionOpChange_toAppendNotesSeedsEmptyStringWhenValueNotString() {
        let original = RuleAction(operation: "set", field: "category", value: .null, type: "id")
        let updated = RuleEditorDraftState.action(afterOperationChange: "append-notes", from: original)
        #expect(updated.field == nil)
        #expect(updated.type == RuleCondition.ValueKind.string.rawValue)
        #expect(updated.value == .string(""))
    }

    // MARK: - action(afterFieldChange:from:)

    @Test func actionFieldChange_toCategoryResetsToIdNull() {
        let original = RuleAction(operation: "set", field: "account", value: .string("a"), type: "id")
        let updated = RuleEditorDraftState.action(afterFieldChange: "category", from: original)
        #expect(updated?.field == "category")
        #expect(updated?.type == RuleCondition.ValueKind.id.rawValue)
        #expect(updated?.value == .null)
    }

    @Test func actionFieldChange_toAmountResetsToNumberZero() {
        let original = RuleAction(operation: "set", field: "category", value: .null, type: "id")
        let updated = RuleEditorDraftState.action(afterFieldChange: "amount", from: original)
        #expect(updated?.field == "amount")
        #expect(updated?.type == RuleCondition.ValueKind.number.rawValue)
        #expect(updated?.value == .number(0))
    }

    @Test func actionFieldChange_toDateResetsToDateDefault() {
        let original = RuleAction(operation: "set", field: "category", value: .null, type: "id")
        let updated = RuleEditorDraftState.action(afterFieldChange: "date", from: original)
        #expect(updated?.field == "date")
        #expect(updated?.type == RuleCondition.ValueKind.date.rawValue)
        guard case .string(let dateText) = updated?.value else {
            Issue.record("expected date string")
            return
        }
        #expect(RuleEditorDraftState.dateSelection(.string(dateText)) != nil)
    }

    @Test func actionFieldChange_toClearedResetsToBoolFalse() {
        let original = RuleAction(operation: "set", field: "category", value: .null, type: "id")
        let updated = RuleEditorDraftState.action(afterFieldChange: "cleared", from: original)
        #expect(updated?.field == "cleared")
        #expect(updated?.type == RuleCondition.ValueKind.boolean.rawValue)
        #expect(updated?.value == .bool(false))
    }

    @Test func actionFieldChange_toSameEditorFieldReturnsNilAndPreservesValue() {
        // Selecting "payee" over an underlying "description" field must NOT wipe
        // the value: the editor field is unchanged, so the result is nil.
        let original = RuleAction(operation: "set", field: "description", value: .string("p1"), type: "id")
        #expect(original.editorField == "payee")
        let updated = RuleEditorDraftState.action(afterFieldChange: "payee", from: original)
        #expect(updated == nil)
    }

    // MARK: - native amount values <-> minor units

    @Test func minorUnits_extractsFromNumber() {
        #expect(RuleEditorDraftState.minorUnits(in: .number(1250)) == 1250)
    }

    @Test func minorUnits_extractsFromNumericString() {
        #expect(RuleEditorDraftState.minorUnits(in: .string("1250")) == 1250)
    }

    @Test func minorUnits_returnsNilForNonNumeric() {
        #expect(RuleEditorDraftState.minorUnits(in: .null) == nil)
        #expect(RuleEditorDraftState.minorUnits(in: .string("abc")) == nil)
        #expect(RuleEditorDraftState.minorUnits(in: .bool(true)) == nil)
    }

    @Test func amountDisplayValue_integralMinorUnitsUsesBudgetScale() {
        #expect(RuleEditorDraftState.amountDisplayValue(.number(1200)) == Decimal(12))
        #expect(RuleEditorDraftState.amountDisplayValue(.number(0)) == Decimal(0))
    }

    @Test func amountDisplayValue_fractionalMinorUnitsUsesExactDecimal() {
        #expect(RuleEditorDraftState.amountDisplayValue(.number(1250)) == Decimal(string: "12.5"))
        #expect(RuleEditorDraftState.amountDisplayValue(.number(1255)) == Decimal(string: "12.55"))
    }

    @Test func amountDisplayValue_acceptsNumericString() {
        #expect(RuleEditorDraftState.amountDisplayValue(.string("1250")) == Decimal(string: "12.5"))
    }

    @Test func amountDisplayValue_nonNumericIsNil() {
        #expect(RuleEditorDraftState.amountDisplayValue(.null) == nil)
        #expect(RuleEditorDraftState.amountDisplayValue(.string("abc")) == nil)
        #expect(RuleEditorDraftState.amountDisplayValue(.bool(true)) == nil)
    }

    @Test func amountValue_convertsDecimalDollarsToMinorUnits() {
        #expect(RuleEditorDraftState.amountValue(from: Decimal(string: "12.50")) == .number(1250))
        #expect(RuleEditorDraftState.amountValue(from: Decimal(string: "12.5")) == .number(1250))
        #expect(RuleEditorDraftState.amountValue(from: Decimal(0)) == .number(0))
    }

    @Test func amountValue_emptyInputStaysInvalid() {
        #expect(RuleEditorDraftState.amountValue(from: nil) == .null)
    }

    @Test func editableString_passesThroughString() {
        #expect(RuleEditorDraftState.editableString(.string("hello")) == "hello")
    }

    @Test func editableString_rendersNumberWithoutCurrencyConversion() {
        #expect(RuleEditorDraftState.editableString(.number(1250)) == "1250")
        #expect(RuleEditorDraftState.editableString(.number(12.5)) == "12.5")
    }

    @Test func editableString_rendersNullAndUnsupportedAsEmpty() {
        #expect(RuleEditorDraftState.editableString(.null) == "")
        #expect(RuleEditorDraftState.editableString(.bool(true)) == "")
        #expect(RuleEditorDraftState.editableString(.array([])) == "")
        #expect(RuleEditorDraftState.editableString(.object([:])) == "")
    }

    // MARK: - range (isbetween) get/set

    @Test func rangeDisplayValue_readsBoundFromObject() {
        let range: RuleJSONValue = .object(["num1": .number(1250), "num2": .number(2500)])
        #expect(RuleEditorDraftState.rangeDisplayValue(range, key: "num1") == Decimal(string: "12.5"))
        #expect(RuleEditorDraftState.rangeDisplayValue(range, key: "num2") == Decimal(25))
    }

    @Test func rangeDisplayValue_isNilForNonObjectOrMissingKey() {
        #expect(RuleEditorDraftState.rangeDisplayValue(.null, key: "num1") == nil)
        #expect(RuleEditorDraftState.rangeDisplayValue(.object(["num2": .number(0)]), key: "num1") == nil)
    }

    @Test func rangeValue_setsBoundOnExistingRange() {
        let current: RuleJSONValue = .object(["num1": .number(0), "num2": .number(0)])
        let result = RuleEditorDraftState.rangeValue(from: Decimal(10), current: current, key: "num1")
        #expect(result == .object(["num1": .number(1000), "num2": .number(0)]))
    }

    @Test func rangeValue_createsRangeWhenCurrentIsNotAnObject() {
        let result = RuleEditorDraftState.rangeValue(from: Decimal(25), current: .null, key: "num2")
        #expect(result == .object(["num2": .number(2500)]))
    }

    @Test func rangeValue_emptyInputStaysInvalid() {
        let result = RuleEditorDraftState.rangeValue(from: nil, current: .null, key: "num1")
        #expect(result == .object(["num1": .null]))
    }

    @Test func rangeValue_emptyBoundDisablesRuleSave() {
        let condition = RuleCondition(
            field: "amount",
            operation: "isbetween",
            value: .object(["num1": .null, "num2": .number(2_500)]),
            type: "number"
        )
        #expect(!condition.canRoundTripAndEvaluate)
    }

    // MARK: - exact date selection

    @Test func dateSelection_roundTripsCalendarDaysWithoutUTCConversion() throws {
        for dayID in ["2026-03-08", "2026-11-01", "2028-02-29"] {
            let selection = try #require(RuleEditorDraftState.dateSelection(.string(dayID)))
            #expect(RuleEditorDraftState.dateValue(from: selection) == .string(dayID))
            #expect(RuleEditorDraftState.dayID(from: selection) == dayID)
        }
    }

    @Test func dateSelection_preservesPartialAndInvalidValuesForTextRepair() {
        #expect(RuleEditorDraftState.dateSelection(.string("2026")) == nil)
        #expect(RuleEditorDraftState.dateSelection(.string("2026-09")) == nil)
        #expect(RuleEditorDraftState.dateSelection(.string("2026-02-30")) == nil)
        #expect(RuleEditorDraftState.dateSelection(.null) == nil)
    }

    // MARK: - multi-value arrays

    @Test func selectedIDs_extractsStringIdentifiers() {
        #expect(RuleEditorDraftState.selectedIDs(.array([.string("a"), .string("b")])) == ["a", "b"])
    }

    @Test func selectedIDs_filtersNonStringsAndNonArrays() {
        #expect(RuleEditorDraftState.selectedIDs(.array([.string("a"), .number(5)])) == ["a"])
        #expect(RuleEditorDraftState.selectedIDs(.null) == [])
        #expect(RuleEditorDraftState.selectedIDs(.string("a")) == [])
    }

    @Test func stringValues_extractsStrings() {
        #expect(RuleEditorDraftState.stringValues(.array([.string("x"), .string("y")])) == ["x", "y"])
        #expect(RuleEditorDraftState.stringValues(.array([.string("x"), .bool(true)])) == ["x"])
        #expect(RuleEditorDraftState.stringValues(.null) == [])
    }

    @Test func appendID_addsNewIdentifier() {
        #expect(
            RuleEditorDraftState.appendID("b", to: .array([.string("a")]))
            == .array([.string("a"), .string("b")])
        )
    }

    @Test func appendID_isNoOpWhenAlreadyPresent() {
        #expect(
            RuleEditorDraftState.appendID("a", to: .array([.string("a")]))
            == .array([.string("a")])
        )
    }

    @Test func appendID_seedsArrayFromNonArrayValue() {
        #expect(RuleEditorDraftState.appendID("b", to: .null) == .array([.string("b")]))
    }

    @Test func removeID_removesMatchingIdentifier() {
        #expect(
            RuleEditorDraftState.removeID("a", from: .array([.string("a"), .string("b")]))
            == .array([.string("b")])
        )
    }

    @Test func removeID_isNoOpWhenAbsent() {
        #expect(
            RuleEditorDraftState.removeID("x", from: .array([.string("a")]))
            == .array([.string("a")])
        )
    }

    @Test func appendStringValue_addsEmptyEntry() {
        #expect(
            RuleEditorDraftState.appendStringValue(to: .array([.string("x")]))
            == .array([.string("x"), .string("")])
        )
    }

    @Test func removeStringValue_removesByIndex() {
        #expect(
            RuleEditorDraftState.removeStringValue(at: 0, from: .array([.string("x"), .string("y")]))
            == .array([.string("y")])
        )
    }

    @Test func removeStringValue_noOpForOutOfBoundsIndex() {
        #expect(
            RuleEditorDraftState.removeStringValue(at: 5, from: .array([.string("x")]))
            == .array([.string("x")])
        )
    }

    // MARK: - payee selection (single vs multi)

    @Test func payeeValue_singleValueReplacesValue() {
        #expect(
            RuleEditorDraftState.payeeValue(afterSelecting: "p1", current: .null, isMultiValue: false)
            == .string("p1")
        )
        #expect(
            RuleEditorDraftState.payeeValue(afterSelecting: "p1", current: .string("p0"), isMultiValue: false)
            == .string("p1")
        )
    }

    @Test func payeeValue_multiValueAddsWhenAbsent() {
        #expect(
            RuleEditorDraftState.payeeValue(afterSelecting: "b", current: .array([.string("a")]), isMultiValue: true)
            == .array([.string("a"), .string("b")])
        )
    }

    @Test func payeeValue_multiValueTogglesOffWhenPresent() {
        #expect(
            RuleEditorDraftState.payeeValue(afterSelecting: "a", current: .array([.string("a"), .string("b")]), isMultiValue: true)
            == .array([.string("b")])
        )
    }
}
