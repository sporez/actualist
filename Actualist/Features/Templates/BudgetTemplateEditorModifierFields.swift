import SwiftUI

struct BudgetTemplateEditorScheduleFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

    var body: some View {
        let options = viewModel.editor.scheduleOptions(for: itemID)
        if options.isEmpty {
            Text("No schedules to cover. Create a schedule before saving this template.")
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            Picker("Schedule", selection: scheduleBinding) {
                Text("Select a schedule").tag(String?.none)
                ForEach(options) { option in
                    Text(option.isAvailable ? option.name : "\(option.name) (unavailable)")
                        .tag(Optional(option.id))
                        .disabled(!option.isAvailable)
                }
            }
            .disabled(!viewModel.isEditable)

            Picker("Savings mode", selection: fullBinding) {
                Text("Save up for the next occurrence").tag(false)
                Text("Cover each occurrence when it occurs").tag(true)
            }
            .disabled(!viewModel.isEditable)

            BudgetTemplateEditorAdjustmentFields(itemID: itemID, viewModel: viewModel, focus: focus)
        }
    }

    private var scheduleBinding: Binding<String?> {
        Binding(
            get: { viewModel.editor.scheduleSelection(for: itemID) },
            set: { viewModel.edit(.setSchedule($0, id: itemID)) }
        )
    }

    private var fullBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .schedule(let value) = viewModel.editor.items.first(where: { $0.id == itemID })?.draft else {
                    return false
                }
                return value.full
            },
            set: { viewModel.edit(.setScheduleFull($0, id: itemID)) }
        )
    }
}

struct BudgetTemplateEditorHistoricalFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

    var body: some View {
        Picker("Mode", selection: modeBinding) {
            Text("Copy a previous month").tag(BudgetTemplateKind.copy)
            Text("Average of previous months").tag(BudgetTemplateKind.average)
        }
        .disabled(!viewModel.isEditable)

        switch viewModel.editor.items.first(where: { $0.id == itemID })?.draft {
        case .copy:
            inputField("Number of months back", field: .lookBack)
        case .average:
            inputField("Number of months back", field: .numMonths)
            BudgetTemplateEditorAdjustmentFields(itemID: itemID, viewModel: viewModel, focus: focus)
        default:
            EmptyView()
        }
    }

    private var modeBinding: Binding<BudgetTemplateKind> {
        Binding(
            get: {
                switch viewModel.editor.items.first(where: { $0.id == itemID })?.draft {
                case .average: .average
                default: .copy
                }
            },
            set: { viewModel.edit(.setKind($0, id: itemID)) }
        )
    }

    private func inputField(
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
}

struct BudgetTemplateEditorAdjustmentFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

    var body: some View {
        Picker("Adjustment", selection: modeBinding) {
            ForEach(BudgetTemplateAdjustmentMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .disabled(!viewModel.inputIsEnabled(.adjustment))

        switch viewModel.editor.adjustmentMode(for: itemID) {
        case .none:
            EmptyView()
        case .fixed:
            BudgetTemplateEditorInput(
                title: "Fixed amount",
                field: .adjustment,
                itemID: itemID,
                viewModel: viewModel,
                focus: focus,
                isDecimal: true
            )
        case .percent:
            Picker("Direction", selection: directionBinding) {
                ForEach(BudgetTemplateAdjustmentDirection.allCases, id: \.self) { direction in
                    Text(direction.title).tag(direction)
                }
            }
            .disabled(!viewModel.inputIsEnabled(.adjustment))
            BudgetTemplateEditorInput(
                title: "Percentage",
                field: .adjustment,
                itemID: itemID,
                viewModel: viewModel,
                focus: focus,
                isDecimal: true
            )
        }
    }

    private var modeBinding: Binding<BudgetTemplateAdjustmentMode> {
        Binding(
            get: { viewModel.editor.adjustmentMode(for: itemID) },
            set: { viewModel.edit(.setAdjustmentMode($0, id: itemID)) }
        )
    }

    private var directionBinding: Binding<BudgetTemplateAdjustmentDirection> {
        Binding(
            get: { viewModel.editor.adjustmentDirection(for: itemID) },
            set: { viewModel.edit(.setAdjustmentDirection($0, id: itemID)) }
        )
    }
}
