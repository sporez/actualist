import SwiftUI

struct BudgetTemplateEditorItemSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var noteMinimumHeight = 68.0
    @ScaledMetric(relativeTo: .body) private var noteMaximumHeight = 110.0
    let item: BudgetTemplateDraftEditor.Item
    let index: Int
    let viewModel: BudgetTemplateEditorViewModel

    var body: some View {
        Section {
            if viewModel.isEditable && item.draft.showsContribution {
                Picker("Template type", selection: kindBinding) {
                    ForEach(viewModel.editor.typeChangeKinds(for: item.id)) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
            }
            fields
            if viewModel.isEditable {
                Button("Delete Template", role: .destructive) {
                    viewModel.edit(.remove(id: item.id))
                }
            }
        } header: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout())
            layout {
                Text(item.draft.kind.title)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                }
                if item.draft.showsContribution {
                    Text(viewModel.contributionText(at: index))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
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
        case .dateTarget:
            BudgetTemplateEditorDateTargetFields(
                itemID: item.id,
                viewModel: viewModel
            )
        case .percentage:
            BudgetTemplateEditorPercentageFields(
                itemID: item.id,
                viewModel: viewModel
            )
        case .balanceLimit(let value):
            balanceLimitFields(value)
        case .refill(let value):
            refillFields(value)
        case .copy(let value):
            BudgetTemplateEditorHistoricalFields(
                itemID: item.id,
                viewModel: viewModel
            )
            priorityField(value.priority)
        case .average(let value):
            BudgetTemplateEditorHistoricalFields(
                itemID: item.id,
                viewModel: viewModel
            )
            priorityField(value.priority)
        case .schedule(let value):
            BudgetTemplateEditorScheduleFields(
                itemID: item.id,
                viewModel: viewModel
            )
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
        if viewModel.editor.fixedStartNeedsRepair(for: item.id) {
            calendarField("Starting date (YYYY-MM-DD)", field: .fixedStart)
        } else {
            DatePicker("Starting", selection: startingDateBinding, displayedComponents: .date)
                .disabled(!viewModel.isEditable)
        }
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
        if value.period == .weekly || viewModel.editor.limitStartNeedsRepair(for: item.id) {
            calendarField("Starting date (YYYY-MM-DD)", field: .limitStart)
        }
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
        if !viewModel.editor.hasBalanceLimit {
            Text("Add a Balance Limit to set the refill target.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
            Button("Add Balance Limit") {
                viewModel.edit(.add(.balanceLimit))
            }
            .disabled(!viewModel.canAddBalanceLimit)
        }
    }

    private func calendarField(_ title: String, field: BudgetTemplateEditorInputField) -> some View {
        BudgetTemplateEditorTextField(
            title: title,
            text: Binding(
                get: { viewModel.inputText(for: field, id: item.id) },
                set: { viewModel.edit(.setInput($0, field: field, id: item.id)) }
            ),
            isMonth: true,
            isEnabled: viewModel.isEditable,
            isValid: viewModel.editor.inputIsValid(for: field, id: item.id)
        )
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
                set: { viewModel.edit(.setInput($0, field: field, id: item.id)) }
            ),
            isDecimal: isDecimal,
            isMonth: false,
            isEnabled: viewModel.inputIsEnabled(field),
            isValid: viewModel.editor.inputIsValid(for: field, id: item.id)
        )
    }

    private var kindBinding: Binding<BudgetTemplateKind> {
        Binding(
            get: { item.draft.kind },
            set: { viewModel.edit(.setKind($0, id: item.id)) }
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
        } else if !viewModel.isEditable {
            VStack(alignment: .leading, spacing: 8) {
                Text("Note").foregroundStyle(ActualistTheme.secondaryText)
                Text(viewModel.noteText(id: item.id))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .accessibilityLabel("Automation note")
        } else {
            LabeledContent("Note") {
                TextEditor(
                    text: Binding(
                        get: { viewModel.noteText(id: item.id) },
                        set: { viewModel.edit(.setNoteText($0, id: item.id)) }
                    )
                )
                .frame(minHeight: noteMinimumHeight, maxHeight: noteMaximumHeight)
                .scrollContentBackground(.hidden)
                .disabled(!viewModel.canEditNotes)
                .accessibilityLabel("Automation note")
            }
        }
        if !viewModel.isPrivacyModeEnabled && viewModel.editor.hasNote(id: item.id) {
            Button("Clear Note", role: .destructive) {
                viewModel.edit(.clearNote(id: item.id))
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
            set: { viewModel.edit(.setFixedCadence($0, id: item.id)) }
        )
    }

    private var startingDateBinding: Binding<Date> {
        Binding(
            get: { viewModel.editor.fixedStartingDate(for: item.id) },
            set: { viewModel.edit(.setFixedStartingDate($0, id: item.id)) }
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
            set: { viewModel.edit(.setLimitPeriod($0, id: item.id)) }
        )
    }

    private var limitWeekdayBinding: Binding<Int> {
        Binding(
            get: { viewModel.editor.limitWeekday(for: item.id) },
            set: { viewModel.edit(.setLimitWeekday($0, id: item.id)) }
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
            set: { viewModel.edit(.setLimitHold($0, id: item.id)) }
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

}

/// Presentation-only text field. The view model owns the binding and validity.
struct BudgetTemplateEditorTextField: View {
    let title: String
    @Binding var text: String
    var isDecimal = false
    var isMonth = false
    let isEnabled: Bool
    let isValid: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .keyboardType(
                    isMonth
                        ? .numbersAndPunctuation
                        : (isDecimal ? .numbersAndPunctuation : .numberPad)
                )
                .multilineTextAlignment(.trailing)
                .disabled(!isEnabled)
                .foregroundStyle(isValid ? ActualistTheme.primaryText : ActualistTheme.danger)
        }
    }
}
