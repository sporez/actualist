import SwiftUI

struct BudgetTemplateEditorScheduleFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel

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

            BudgetTemplateEditorAdjustmentFields(itemID: itemID, viewModel: viewModel)
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
            BudgetTemplateEditorAdjustmentFields(itemID: itemID, viewModel: viewModel)
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
        BudgetTemplateEditorTextField(
            title: title,
            text: Binding(
                get: { viewModel.inputText(for: field, id: itemID) },
                set: { viewModel.edit(.setInput($0, field: field, id: itemID)) }
            ),
            isEnabled: viewModel.inputIsEnabled(field),
            isValid: viewModel.editor.inputIsValid(for: field, id: itemID)
        )
    }
}

struct BudgetTemplateEditorAdjustmentFields: View {
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel

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
            BudgetTemplateEditorTextField(
                title: "Fixed amount",
                text: adjustmentInput,
                isDecimal: true,
                isEnabled: viewModel.inputIsEnabled(.adjustment),
                isValid: viewModel.editor.inputIsValid(for: .adjustment, id: itemID)
            )
        case .percent:
            Picker("Direction", selection: directionBinding) {
                ForEach(BudgetTemplateAdjustmentDirection.allCases, id: \.self) { direction in
                    Text(direction.title).tag(direction)
                }
            }
            .disabled(!viewModel.inputIsEnabled(.adjustment))
            BudgetTemplateEditorTextField(
                title: "Percentage",
                text: adjustmentInput,
                isDecimal: true,
                isEnabled: viewModel.inputIsEnabled(.adjustment),
                isValid: viewModel.editor.inputIsValid(for: .adjustment, id: itemID)
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

    private var adjustmentInput: Binding<String> {
        Binding(
            get: { viewModel.inputText(for: .adjustment, id: itemID) },
            set: { viewModel.edit(.setInput($0, field: .adjustment, id: itemID)) }
        )
    }
}
