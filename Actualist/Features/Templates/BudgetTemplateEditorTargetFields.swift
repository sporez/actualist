import SwiftUI

struct BudgetTemplateEditorDateTargetFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel

    var body: some View {
        amountField
        monthField(
            title: "Target month",
            field: .targetMonth
        )
        Toggle("Repeats", isOn: repeatsBinding)
            .disabled(!viewModel.isEditable)
        if viewModel.editor.dateTargetRepeats(for: itemID) {
            integerField("Repeat every", field: .repeatInterval)
            Picker("Period", selection: annualBinding) {
                Text("Months").tag(false)
                Text("Years").tag(true)
            }
            .disabled(!viewModel.isEditable)
        }
        Toggle("Allow early spending", isOn: earlySpendingBinding)
            .disabled(!viewModel.isEditable)
        if viewModel.editor.dateTargetAllowsEarlySpending(for: itemID) {
            monthField(
                title: "Start spending in",
                field: .spendStartMonth
            )
        }
        priorityField
        Text("Use YYYY-MM for month fields. Repeating targets can be anchored in a past month.")
            .font(.footnote)
            .foregroundStyle(ActualistTheme.secondaryText)
    }

    private var amountField: some View {
        BudgetTemplateEditorTextField(
            title: "Total",
            text: inputBinding(for: .amount),
            isDecimal: true,
            isEnabled: viewModel.inputIsEnabled(.amount),
            isValid: viewModel.editor.inputIsValid(for: .amount, id: itemID)
        )
    }

    private func monthField(
        title: String,
        field: BudgetTemplateEditorInputField
    ) -> some View {
        BudgetTemplateEditorTextField(
            title: title,
            text: inputBinding(for: field),
            isMonth: true,
            isEnabled: viewModel.inputIsEnabled(field),
            isValid: viewModel.editor.inputIsValid(for: field, id: itemID)
        )
    }

    private func integerField(
        _ title: String,
        field: BudgetTemplateEditorInputField
    ) -> some View {
        BudgetTemplateEditorTextField(
            title: title,
            text: inputBinding(for: field),
            isEnabled: viewModel.inputIsEnabled(field),
            isValid: viewModel.editor.inputIsValid(for: field, id: itemID)
        )
    }

    private var priorityField: some View {
        integerField("Priority", field: .priority)
    }

    private func inputBinding(for field: BudgetTemplateEditorInputField) -> Binding<String> {
        Binding(
            get: { viewModel.inputText(for: field, id: itemID) },
            set: { viewModel.edit(.setInput($0, field: field, id: itemID)) }
        )
    }

    private var repeatsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.editor.dateTargetRepeats(for: itemID) },
            set: { viewModel.edit(.setDateTargetRepeats($0, id: itemID)) }
        )
    }

    private var annualBinding: Binding<Bool> {
        Binding(
            get: { viewModel.editor.dateTargetIsAnnual(for: itemID) },
            set: { viewModel.edit(.setDateTargetAnnual($0, id: itemID)) }
        )
    }

    private var earlySpendingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.editor.dateTargetAllowsEarlySpending(for: itemID) },
            set: { viewModel.edit(.setDateTargetEarlySpending($0, id: itemID)) }
        )
    }
}

struct BudgetTemplateEditorPercentageFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel

    var body: some View {
        Picker("Income source", selection: sourceBinding) {
            Text("Choose an income source").tag("")
            ForEach(viewModel.editor.percentageSourceOptions(for: itemID)) { option in
                Text(option.name)
                    .tag(option.id)
                    .disabled(!option.isAvailable)
            }
        }
        .disabled(!viewModel.isEditable)
        BudgetTemplateEditorTextField(
            title: "Percentage",
            text: inputBinding(for: .percent),
            isDecimal: true,
            isEnabled: viewModel.isEditable,
            isValid: viewModel.editor.inputIsValid(for: .percent, id: itemID)
        )
        Picker("Percentage of", selection: previousBinding) {
            Text("This month").tag(false)
            Text("Last month").tag(true)
        }
        .disabled(!viewModel.isEditable)
        priorityField
        Text("Percentage templates use income from the selected period. Available funds can only use this month.")
            .font(.footnote)
            .foregroundStyle(ActualistTheme.secondaryText)
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { viewModel.editor.percentageSourceSelection(for: itemID) },
            set: { viewModel.edit(.setPercentageSource($0, id: itemID)) }
        )
    }

    private var previousBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .percentage(let current) = viewModel.editor.items.first(where: { $0.id == itemID })?.draft else {
                    return false
                }
                return current.previous
            },
            set: { viewModel.edit(.setPercentagePrevious($0, id: itemID)) }
        )
    }

    private var priorityField: some View {
        BudgetTemplateEditorTextField(
            title: "Priority",
            text: inputBinding(for: .priority),
            isEnabled: viewModel.isEditable,
            isValid: viewModel.editor.inputIsValid(for: .priority, id: itemID)
        )
    }

    private func inputBinding(for field: BudgetTemplateEditorInputField) -> Binding<String> {
        Binding(
            get: { viewModel.inputText(for: field, id: itemID) },
            set: { viewModel.edit(.setInput($0, field: field, id: itemID)) }
        )
    }
}
