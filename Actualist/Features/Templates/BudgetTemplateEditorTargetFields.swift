import SwiftUI

struct BudgetTemplateEditorDateTargetFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

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
        Text("Repeating targets can be anchored in a past month.")
            .font(.footnote)
            .foregroundStyle(ActualistTheme.secondaryText)
    }

    private var amountField: some View {
        BudgetTemplateEditorInput(
            title: "Total",
            field: .amount,
            itemID: itemID,
            viewModel: viewModel,
            focus: focus,
            isDecimal: true
        )
    }

    private func monthField(
        title: String,
        field: BudgetTemplateEditorInputField
    ) -> some View {
        BudgetTemplateEditorMonthField(
            title: title,
            field: field,
            itemID: itemID,
            viewModel: viewModel,
            focus: focus
        )
    }

    private func integerField(
        _ title: String,
        field: BudgetTemplateEditorInputField
    ) -> some View {
        BudgetTemplateEditorInput(
            title: title,
            field: field,
            itemID: itemID,
            viewModel: viewModel,
            focus: focus
        )
    }

    private var priorityField: some View {
        integerField("Priority", field: .priority)
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
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

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
        BudgetTemplateEditorInput(
            title: "Percentage",
            field: .percent,
            itemID: itemID,
            viewModel: viewModel,
            focus: focus,
            isDecimal: true
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
        BudgetTemplateEditorInput(
            title: "Priority",
            field: .priority,
            itemID: itemID,
            viewModel: viewModel,
            focus: focus
        )
    }
}
