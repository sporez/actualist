import SwiftUI

struct BudgetTemplateEditorItemSection: View {
    let item: BudgetTemplateEditorViewModel.Item
    let index: Int
    let viewModel: BudgetTemplateEditorViewModel

    var body: some View {
        Section {
            fields
            if viewModel.isEditable {
                Button("Delete Template", role: .destructive) {
                    viewModel.remove(id: item.id)
                }
            }
        } header: {
            HStack {
                Text(item.draft.kind.title)
                Spacer()
                if item.draft.showsContribution {
                    Text(viewModel.contributionText(at: index))
                        .monospacedDigit()
                }
            }
        }
        .settingsSectionChrome()
    }

    @ViewBuilder
    private var fields: some View {
        switch item.draft {
        case .monthlyFixed(let value):
            monthlyFixedFields(value)
        case .dateTarget, .percentage, .balanceLimit, .refill:
            Text("This template type is not editable yet.")
                .foregroundStyle(ActualistTheme.secondaryText)
        case .copy(let value):
            integerField("Months back", value: String(value.lookBack)) { text in
                viewModel.setLookBack(text, id: item.id)
            }
            priorityField(value.priority)
        case .average(let value):
            integerField("Months", value: String(value.numMonths)) { text in
                viewModel.setNumMonths(text, id: item.id)
            }
            priorityField(value.priority)
        case .schedule(let value):
            scheduleFields(value)
            priorityField(value.priority)
        case .remainder(let value):
            decimalField("Weight", value: weightText(value.weight)) { text in
                viewModel.setWeight(text, id: item.id)
            }
        case .goal(let value):
            amountField("Target", amount: value.amount) { text in
                viewModel.setAmount(text, id: item.id)
            }
        }
    }

    @ViewBuilder
    private func monthlyFixedFields(_ value: BudgetTemplateDraft.MonthlyFixed) -> some View {
        amountField("Amount", amount: value.amount) { text in
            viewModel.setAmount(text, id: item.id)
        }
        Toggle("Cap available", isOn: capEnabledBinding(value))
            .disabled(!viewModel.isEditable)
        if let upTo = value.upTo {
            amountField("Cap", amount: upTo.amount) { text in
                viewModel.setCapAmount(text, id: item.id)
            }
            Toggle("Hold extra over the cap", isOn: holdBinding)
                .disabled(!viewModel.isEditable)
        }
        priorityField(value.priority)
    }

    @ViewBuilder
    private func scheduleFields(_ value: BudgetTemplateDraft.Schedule) -> some View {
        if viewModel.schedules.isEmpty {
            Text("No schedules to cover.")
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            Picker("Schedule", selection: scheduleBinding(value)) {
                Text("Select a schedule").tag(String?.none)
                ForEach(viewModel.schedules) { option in
                    Text(option.name).tag(Optional(option.id))
                }
            }
            .disabled(!viewModel.isEditable)
        }
    }

    private func amountField(
        _ title: String,
        amount: Double,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        BudgetTemplateCommitTextField(
            title: title,
            text: BudgetTemplateAmountInput.formatAmount(amount, currency: viewModel.currency),
            isDecimal: true,
            isEnabled: viewModel.isEditable,
            onCommit: onCommit
        )
    }

    private func integerField(
        _ title: String,
        value: String,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        BudgetTemplateCommitTextField(
            title: title,
            text: value,
            isDecimal: false,
            isEnabled: viewModel.isEditable,
            onCommit: onCommit
        )
    }

    private func decimalField(
        _ title: String,
        value: String,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        BudgetTemplateCommitTextField(
            title: title,
            text: value,
            isDecimal: true,
            isEnabled: viewModel.isEditable,
            onCommit: onCommit
        )
    }

    private func priorityField(_ priority: Int) -> some View {
        integerField("Priority", value: String(priority)) { text in
            viewModel.setPriority(text, id: item.id)
        }
    }

    private func capEnabledBinding(_ value: BudgetTemplateDraft.MonthlyFixed) -> Binding<Bool> {
        Binding(
            get: { value.upTo != nil },
            set: { viewModel.setCapEnabled($0, id: item.id) }
        )
    }

    private var holdBinding: Binding<Bool> {
        Binding(
            get: {
                if case .monthlyFixed(let value) = item.draft {
                    return value.upTo?.hold ?? false
                }
                return false
            },
            set: { viewModel.setHold($0, id: item.id) }
        )
    }

    private func scheduleBinding(_ value: BudgetTemplateDraft.Schedule) -> Binding<String?> {
        Binding(
            get: {
                if let id = value.scheduleId,
                   viewModel.schedules.contains(where: { $0.id == id }) {
                    return id
                }
                return viewModel.schedules.first { $0.name == value.name }?.id
            },
            set: { selectedID in
                guard let selectedID,
                      let option = viewModel.schedules.first(where: { $0.id == selectedID }) else {
                    return
                }
                viewModel.setSchedule(option, id: item.id)
            }
        )
    }

    private func weightText(_ weight: Double) -> String {
        if weight.rounded() == weight {
            return String(Int(weight))
        }
        return String(weight)
    }
}

/// Presentation-only text field. Commits the typed string; the view model parses.
struct BudgetTemplateCommitTextField: View {
    let title: String
    let text: String
    var isDecimal = false
    let isEnabled: Bool
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $draft)
                .keyboardType(isDecimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .disabled(!isEnabled)
                .focused($isFocused)
        }
        .onAppear { draft = text }
        .onChange(of: text) { _, newValue in
            if !isFocused {
                draft = newValue
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                onCommit(draft)
            }
        }
        .onChange(of: draft) { _, newValue in
            if isFocused {
                onCommit(newValue)
            }
        }
    }
}
