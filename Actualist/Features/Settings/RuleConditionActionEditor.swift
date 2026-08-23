import SwiftUI

/// Field and operation rows for a single rule condition. Renders layout only;
/// field-change and operation-change payload re-derivation is delegated to
/// ``RuleEditorDraftState`` so the view never normalizes payload values in a
/// binding setter.
struct RuleConditionEditor: View {
    @Binding var condition: RuleCondition
    let options: RuleEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RuleMenuPickerRow("Field", selection: editorFieldBinding) {
                ForEach(RuleCondition.editableFields, id: \.value) { Text($0.name).tag($0.value) }
            }
            RuleMenuPickerRow("Comparison", selection: $condition.operation) {
                ForEach(operations, id: \.self) { Text(RulePresentation.operationName($0)).tag($0) }
            }
            if condition.operation != "onBudget" && condition.operation != "offBudget" {
                RuleValueEditor(value: $condition.value, field: condition.editorField, operation: condition.operation, options: options)
            }
        }
        .onChange(of: condition.operation) {
            condition.value = RuleEditorDraftState.valueForChangedOperation(
                currentValue: condition.value,
                operation: condition.operation,
                field: condition.field
            )
        }
    }

    private var operations: [String] { RuleCondition.operations(for: condition.editorField) }

    private var editorFieldBinding: Binding<String> {
        Binding(
            get: { condition.editorField },
            set: { newField in
                condition = RuleEditorDraftState.condition(afterFieldChange: newField, from: condition)
            }
        )
    }
}

/// Operation and field rows for a single rule action. Renders layout only;
/// operation-change and field-change payload re-derivation is delegated to
/// ``RuleEditorDraftState``.
struct RuleActionEditor: View {
    @Binding var action: RuleAction
    let options: RuleEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RuleMenuPickerRow("Action", selection: $action.operation) {
                Text("Set field").tag("set")
                Text("Prepend notes").tag("prepend-notes")
                Text("Append notes").tag("append-notes")
                Text("Delete transaction").tag("delete-transaction")
                Text("Set split amount").tag("set-split-amount")
            }
            if action.operation == "set" {
                RuleMenuPickerRow("Field", selection: actionFieldBinding) {
                    ForEach(["account", "amount", "category", "date", "notes", "payee", "cleared"], id: \.self) {
                        Text(RulePresentation.fieldName($0)).tag($0)
                    }
                }
            }
            if action.operation == "set-split-amount" {
                RuleMenuPickerRow("Method", selection: splitMethodBinding) {
                    Text("Fixed amount").tag("fixed-amount")
                    Text("Percent").tag("fixed-percent")
                    Text("Remainder").tag("remainder")
                }
            }
            if action.operation == "set" || action.operation == "set-split-amount" {
                RuleMenuPickerRow("Apply to", selection: splitTargetBinding) {
                    if action.operation == "set" {
                        Text("Whole transaction").tag(-1)
                    }
                    ForEach(0..<8, id: \.self) { index in
                        Text("Split \(index + 1)").tag(index)
                    }
                }
            }
            if action.operation != "delete-transaction",
               action.operation != "set-split-amount" || action.splitMethod != "remainder" {
                RuleValueEditor(
                    value: $action.value,
                    field: action.operation == "set-split-amount"
                        ? (action.splitMethod == "fixed-amount" ? "amount" : "percent")
                        : (action.editorField ?? action.operation),
                    operation: action.operation,
                    options: options
                )
            }
        }
        .onChange(of: action.operation) {
            action = RuleEditorDraftState.action(afterOperationChange: action.operation, from: action)
        }
    }

    private var splitMethodBinding: Binding<String> {
        Binding(
            get: { action.splitMethod ?? "fixed-amount" },
            set: { action = RuleEditorDraftState.action(action, settingSplitMethod: $0) }
        )
    }

    private var splitTargetBinding: Binding<Int> {
        Binding(
            get: { action.splitIndex ?? (action.operation == "set-split-amount" ? 0 : -1) },
            set: { newValue in
                action = RuleEditorDraftState.action(
                    action,
                    settingSplitIndex: newValue < 0 ? nil : newValue
                )
            }
        )
    }

    private var actionFieldBinding: Binding<String> {
        Binding(
            get: { action.editorField ?? "category" },
            set: { newField in
                if let updated = RuleEditorDraftState.action(afterFieldChange: newField, from: action) {
                    action = updated
                }
            }
        )
    }
}
