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
            }
            if action.operation == "set" {
                RuleMenuPickerRow("Field", selection: actionFieldBinding) {
                    ForEach(["account", "amount", "category", "date", "notes", "payee", "cleared"], id: \.self) {
                        Text(RulePresentation.fieldName($0)).tag($0)
                    }
                }
            }
            if action.operation != "delete-transaction" {
                RuleValueEditor(
                    value: $action.value,
                    field: action.editorField ?? action.operation,
                    operation: action.operation,
                    options: options
                )
            }
        }
        .onChange(of: action.operation) {
            action = RuleEditorDraftState.action(afterOperationChange: action.operation, from: action)
        }
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
