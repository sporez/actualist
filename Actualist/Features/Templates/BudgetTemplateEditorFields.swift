import SwiftUI

struct BudgetTemplateEditorItemSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: BudgetTemplateDraftEditor.Item
    let index: Int
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

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
                if viewModel.showsContributionBreakdown && item.draft.showsContribution {
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
        case .monthlyFixed:
            monthlyFixedFields
        case .dateTarget:
            BudgetTemplateEditorDateTargetFields(
                itemID: item.id,
                viewModel: viewModel,
                focus: focus
            )
        case .percentage:
            BudgetTemplateEditorPercentageFields(
                itemID: item.id,
                viewModel: viewModel,
                focus: focus
            )
        case .balanceLimit(let value):
            balanceLimitFields(value)
        case .refill:
            refillFields
        case .copy:
            BudgetTemplateEditorHistoricalFields(
                itemID: item.id,
                viewModel: viewModel,
                focus: focus
            )
            inputField("Priority", field: .priority)
        case .average:
            BudgetTemplateEditorHistoricalFields(
                itemID: item.id,
                viewModel: viewModel,
                focus: focus
            )
            inputField("Priority", field: .priority)
        case .schedule:
            BudgetTemplateEditorScheduleFields(
                itemID: item.id,
                viewModel: viewModel,
                focus: focus
            )
            inputField("Priority", field: .priority)
        case .remainder:
            inputField("Weight", field: .weight, isDecimal: true)
        case .goal:
            inputField("Target", field: .amount, isDecimal: true)
        }
        BudgetTemplateEditorNoteField(itemID: item.id, viewModel: viewModel, focus: focus)
    }

    @ViewBuilder
    private var monthlyFixedFields: some View {
        inputField("Amount", field: .amount, isDecimal: true)
        inputField("Every", field: .interval)
        Picker("Period", selection: cadenceBinding) {
            ForEach(BudgetTemplateCadence.allCases, id: \.self) { cadence in
                Text(cadenceLabel(cadence)).tag(cadence)
            }
        }
        .disabled(!viewModel.isEditable)
        if viewModel.editor.fixedStartUsesTextField(for: item.id) {
            inputField("Starting date", field: .fixedStart, isMonth: true)
        } else {
            DatePicker("Starting", selection: startingDateBinding, displayedComponents: .date)
                .disabled(!viewModel.isEditable)
        }
        inputField("Priority", field: .priority)
    }

    @ViewBuilder
    private func balanceLimitFields(_ value: BudgetTemplateDraft.BalanceLimit) -> some View {
        inputField("Amount", field: .amount, isDecimal: true)
        Picker("Every", selection: limitPeriodBinding) {
            ForEach(BudgetTemplateLimitPeriod.allCases, id: \.self) { period in
                Text(limitPeriodLabel(period)).tag(period)
            }
        }
        .disabled(!viewModel.isEditable)
        if value.period == .weekly || viewModel.editor.limitStartUsesTextField(for: item.id) {
            inputField("Starting date", field: .limitStart, isMonth: true)
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
    private var refillFields: some View {
        inputField("Priority", field: .priority)
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

    private func inputField(
        _ title: String,
        field: BudgetTemplateEditorInputField,
        isDecimal: Bool = false,
        isMonth: Bool = false
    ) -> some View {
        BudgetTemplateEditorInput(
            title: title,
            field: field,
            itemID: item.id,
            viewModel: viewModel,
            focus: focus,
            isDecimal: isDecimal,
            isMonth: isMonth
        )
    }

    private var kindBinding: Binding<BudgetTemplateKind> {
        Binding(
            get: { item.draft.kind },
            set: { viewModel.edit(.setKind($0, id: item.id)) }
        )
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
