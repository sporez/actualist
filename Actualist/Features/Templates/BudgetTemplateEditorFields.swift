import SwiftUI

struct BudgetTemplateEditorItemSection: View {
    let item: BudgetTemplateEditorViewModel.Item
    let index: Int
    let viewModel: BudgetTemplateEditorViewModel

    var body: some View {
        Section {
            if viewModel.isEditable && item.draft.showsContribution {
                Picker("Template type", selection: kindBinding) {
                    ForEach(viewModel.typeChangeKinds(for: item.id)) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
            }
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
        case .dateTarget, .percentage:
            Text("This template type is not editable yet.")
                .foregroundStyle(ActualistTheme.secondaryText)
        case .balanceLimit(let value):
            balanceLimitFields(value)
        case .refill(let value):
            refillFields(value)
        case .copy(let value):
            integerField("Months back", field: .lookBack)
            priorityField(value.priority)
        case .average(let value):
            integerField("Months", field: .numMonths)
            priorityField(value.priority)
        case .schedule(let value):
            scheduleFields(value)
            priorityField(value.priority)
        case .remainder:
            decimalField("Weight", field: .weight)
        case .goal:
            amountField("Target", field: .amount)
        }
        noteField
    }

    @ViewBuilder
    private func monthlyFixedFields(_ value: BudgetTemplateDraft.MonthlyFixed) -> some View {
        amountField("Amount", field: .amount)
        integerField("Every", field: .interval)
        Picker("Period", selection: cadenceBinding) {
            ForEach(BudgetTemplateCadence.allCases, id: \.self) { cadence in
                Text(cadenceLabel(cadence)).tag(cadence)
            }
        }
        .disabled(!viewModel.isEditable)
        DatePicker("Starting", selection: startingDateBinding, displayedComponents: .date)
            .disabled(!viewModel.isEditable)
        priorityField(value.priority)
    }

    @ViewBuilder
    private func balanceLimitFields(_ value: BudgetTemplateDraft.BalanceLimit) -> some View {
        amountField("Amount", field: .amount)
        Picker("Every", selection: limitPeriodBinding) {
            ForEach(BudgetTemplateLimitPeriod.allCases, id: \.self) { period in
                Text(limitPeriodLabel(period)).tag(period)
            }
        }
        .disabled(!viewModel.isEditable)
        if value.period == .weekly {
            Picker("Weekday", selection: limitWeekdayBinding) {
                ForEach(1...7, id: \.self) { weekday in
                    Text(BudgetTemplateEditorCalendar.weekdayName(weekday)).tag(weekday)
                }
            }
            .disabled(!viewModel.isEditable)
        }
        Toggle("Retain existing funds over the cap", isOn: limitHoldBinding)
            .disabled(!viewModel.isEditable)
        Text("Weekly and daily caps change with the number of days or weeks in each month.")
            .font(.footnote)
            .foregroundStyle(ActualistTheme.secondaryText)
    }

    @ViewBuilder
    private func refillFields(_ value: BudgetTemplateDraft.Refill) -> some View {
        priorityField(value.priority)
        if !viewModel.hasBalanceLimit {
            Text("Add a Balance Limit to set the refill target.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
            Button("Add Balance Limit") {
                viewModel.add(.balanceLimit)
            }
            .disabled(!viewModel.canAddBalanceLimit)
        }
    }

    @ViewBuilder
    private func scheduleFields(_ value: BudgetTemplateDraft.Schedule) -> some View {
        let options = viewModel.scheduleOptions(for: item.id)
        if options.isEmpty {
            Text("No schedules to cover.")
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            Picker("Schedule", selection: scheduleBinding(value)) {
                Text("Select a schedule").tag(String?.none)
                ForEach(options) { option in
                    Text(option.isAvailable ? option.name : "\(option.name) (unavailable)")
                        .tag(Optional(option.id))
                        .disabled(!option.isAvailable)
                }
            }
            .disabled(!viewModel.isEditable)
        }
    }

    private func amountField(
        _ title: String,
        field: BudgetTemplateEditorInputField
    ) -> some View {
        inputField(title, field: field, isDecimal: true)
    }

    private func integerField(
        _ title: String,
        field: BudgetTemplateEditorInputField
    ) -> some View {
        inputField(title, field: field, isDecimal: false)
    }

    private func decimalField(
        _ title: String,
        field: BudgetTemplateEditorInputField
    ) -> some View {
        inputField(title, field: field, isDecimal: true)
    }

    private func priorityField(_ priority: Int) -> some View {
        integerField("Priority", field: .priority)
    }

    private func inputField(
        _ title: String,
        field: BudgetTemplateEditorInputField,
        isDecimal: Bool
    ) -> some View {
        BudgetTemplateEditorTextField(
            title: title,
            text: Binding(
                get: { viewModel.inputText(for: field, id: item.id) },
                set: { viewModel.setInput($0, field: field, id: item.id) }
            ),
            isDecimal: isDecimal,
            isEnabled: viewModel.isEditable,
            isValid: viewModel.inputIsValid(for: field, id: item.id)
        )
    }

    private var kindBinding: Binding<BudgetTemplateKind> {
        Binding(
            get: { item.draft.kind },
            set: { viewModel.setKind($0, id: item.id) }
        )
    }

    @ViewBuilder
    private var noteField: some View {
        if viewModel.isPrivacyModeEnabled {
            LabeledContent("Note") {
                Text("Hidden in Sample Values")
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            Text("Disable Sample Values to view or edit automation notes.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            LabeledContent("Note") {
                TextEditor(
                    text: Binding(
                        get: { viewModel.noteText(id: item.id) },
                        set: { viewModel.setNoteText($0, id: item.id) }
                    )
                )
                .frame(minHeight: 68, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .disabled(!viewModel.canEditNotes)
                .accessibilityLabel("Automation note")
            }
        }
        if !viewModel.isPrivacyModeEnabled && viewModel.hasNote(id: item.id) {
            Button("Clear Note", role: .destructive) {
                viewModel.clearNote(id: item.id)
            }
            .disabled(!viewModel.canEditNotes)
        }
    }

    private var cadenceBinding: Binding<BudgetTemplateCadence> {
        Binding(
            get: {
                if case .monthlyFixed(let value) = item.draft {
                    return value.cadence
                }
                return .month
            },
            set: { viewModel.setFixedCadence($0, id: item.id) }
        )
    }

    private var startingDateBinding: Binding<Date> {
        Binding(
            get: { viewModel.fixedStartingDate(for: item.id) },
            set: { viewModel.setFixedStartingDate($0, id: item.id) }
        )
    }

    private var limitPeriodBinding: Binding<BudgetTemplateLimitPeriod> {
        Binding(
            get: {
                if case .balanceLimit(let value) = item.draft {
                    return value.period
                }
                return .monthly
            },
            set: { viewModel.setLimitPeriod($0, id: item.id) }
        )
    }

    private var limitWeekdayBinding: Binding<Int> {
        Binding(
            get: { viewModel.limitWeekday(for: item.id) },
            set: { viewModel.setLimitWeekday($0, id: item.id) }
        )
    }

    private var limitHoldBinding: Binding<Bool> {
        Binding(
            get: {
                if case .balanceLimit(let value) = item.draft {
                    return value.hold
                }
                return false
            },
            set: { viewModel.setLimitHold($0, id: item.id) }
        )
    }

    private func cadenceLabel(_ cadence: BudgetTemplateCadence) -> String {
        switch cadence {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    private func limitPeriodLabel(_ period: BudgetTemplateLimitPeriod) -> String {
        switch period {
        case .daily: "Day"
        case .weekly: "Week"
        case .monthly: "Month"
        }
    }

    private func scheduleBinding(_ value: BudgetTemplateDraft.Schedule) -> Binding<String?> {
        Binding(
            get: {
                if let id = value.scheduleId,
                   viewModel.scheduleOptions(for: item.id).contains(where: { $0.id == id }) {
                    return id
                }
                return value.scheduleId == nil
                    ? viewModel.schedules.first { $0.name == value.name }?.id
                    : nil
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

}

/// Presentation-only text field. The view model owns the binding and validity.
struct BudgetTemplateEditorTextField: View {
    let title: String
    @Binding var text: String
    var isDecimal = false
    let isEnabled: Bool
    let isValid: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .keyboardType(isDecimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .disabled(!isEnabled)
                .foregroundStyle(isValid ? ActualistTheme.primaryText : ActualistTheme.danger)
        }
    }
}
