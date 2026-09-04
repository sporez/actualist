import SwiftUI

enum BudgetTemplateEditorFocus: Hashable {
    case input(BudgetTemplateEditorInputKey)
    case note(UUID)

    var inputKey: BudgetTemplateEditorInputKey? {
        if case .input(let key) = self { return key }
        return nil
    }
}

struct BudgetTemplateEditorInput: View {
    @Environment(\.locale) private var locale
    let title: String
    let field: BudgetTemplateEditorInputField
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding
    var isDecimal = false
    var isMonth = false

    var body: some View {
        if let range = field.integerRange {
            BudgetTemplateEditorStepper(title: title, field: field, itemID: itemID, range: range, viewModel: viewModel)
        } else {
            textField
        }
    }

    private var textField: some View {
        let inputColor = viewModel.inputShowsError(for: field, id: itemID)
            ? ActualistTheme.danger : ActualistTheme.primaryText
        return VStack(alignment: .leading) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            input
            .keyboardType(viewModel.isMoneyInput(field, id: itemID) && field == .amount
                ? .decimalPad : (isMonth || isDecimal ? .numbersAndPunctuation : .numberPad))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .multilineTextAlignment(.leading)
            .focused(focus, equals: .input(.init(itemID: itemID, field: field)))
            .submitLabel(.done)
            .onSubmit { focus.wrappedValue = nil }
            .disabled(!viewModel.inputIsEnabled(field))
            .foregroundStyle(inputColor)
            .accessibilityLabel(title)
        }
    }

    @ViewBuilder private var input: some View {
        if viewModel.isMoneyInput(field, id: itemID) && !viewModel.isPrivacyModeEnabled {
            TextField(title, value: amountBinding,
                      format: BudgetTemplateMoneyFormat(currency: viewModel.editor.currency, locale: locale))
        } else {
            TextField(title, text: Binding(
                get: { viewModel.inputText(for: field, id: itemID) },
                set: { viewModel.edit(.setInput($0, field: field, id: itemID)) }
            ))
        }
    }

    private var amountBinding: Binding<Decimal?> {
        Binding(
            get: { viewModel.numericAmount(for: field, id: itemID) },
            set: { viewModel.setNumericAmount($0, field: field, id: itemID) }
        )
    }
}

struct BudgetTemplateEditorStepper: View {
    let title: String
    let field: BudgetTemplateEditorInputField
    let itemID: UUID
    let range: ClosedRange<Int>
    let viewModel: BudgetTemplateEditorViewModel

    var body: some View {
        Stepper(value: Binding(
            get: { viewModel.integerValue(for: field, id: itemID) },
            set: { viewModel.setIntegerValue($0, field: field, id: itemID) }
        ), in: range) {
            LabeledContent(title) {
                Text(viewModel.integerValue(for: field, id: itemID), format: .number)
                    .monospacedDigit()
            }
        }
        .disabled(!viewModel.isEditable)
        .accessibilityIdentifier("template-\(field)-stepper")
    }
}

struct BudgetTemplateEditorNoteField: View {
    @ScaledMetric(relativeTo: .body) private var noteHeight = 100.0
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

    var body: some View {
        if viewModel.isPrivacyModeEnabled {
            LabeledContent("Note", value: "Hidden in Sample Values")
            Text("Disable Sample Values to view or edit automation notes.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Note")
                    .foregroundStyle(ActualistTheme.secondaryText)
                if viewModel.isEditable {
                    TextEditor(text: Binding(
                        get: { viewModel.noteText(id: itemID) },
                        set: { viewModel.edit(.setNoteText($0, id: itemID)) }
                    ))
                    .frame(height: noteHeight)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, -5)
                    .focused(focus, equals: .note(itemID))
                    .accessibilityLabel("Automation note")
                } else {
                    Text(viewModel.noteText(id: itemID))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel("Automation note")
                }
            }
            if viewModel.isEditable {
                Button("Clear Note", role: .destructive) {
                    viewModel.edit(.clearNote(id: itemID))
                }
                .disabled(!viewModel.canEditNotes || !viewModel.editor.hasNote(id: itemID))
            }
        }
    }
}
