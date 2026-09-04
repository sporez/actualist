import SwiftUI

/// Identifier, multi-value, range, amount, date, number, Boolean, and string
/// value controls for a single rule condition/action value.
///
/// This view renders layout only. All payload interpretation and normalization
/// (native amount values <-> Actual minor units, range get/set, date selection,
/// multi-value add/remove,
/// payee selection) is delegated to ``RuleEditorDraftState`` so the view never
/// computes a payload value in a binding setter.
struct RuleValueEditor: View {
    @Environment(\.budgetCurrency) private var currency
    @Environment(\.locale) private var locale
    @Binding var value: RuleJSONValue
    let field: String
    let operation: String
    let options: RuleEditorOptions?
    let inputID: UUID
    let focus: FocusState<RuleEditorFocus?>.Binding
    @State private var isPayeePickerPresented = false

    var body: some View {
        Group {
            if operation == "isbetween" {
                rangeEditor
            } else if ["cleared", "reconciled", "transfer", "parent"].contains(field) {
                RuleMenuPickerRow("Value", selection: boolBinding) {
                    Text("Yes").tag(true)
                    Text("No").tag(false)
                }
            } else if isMultiValue {
                multiValueEditor
            } else if RuleCondition.valueKind(for: field) == .id {
                identifierEditor
            } else if RuleCondition.valueKind(for: field) == .date {
                dateEditor
            } else if RuleCondition.valueKind(for: field) == .number {
                amountEditor
            } else {
                labeledInput("Value") {
                    TextField(placeholder, text: stringBinding)
                        .textInputAutocapitalization(field == "notes" ? .sentences : .never)
                        .focused(focus, equals: .value(inputID))
                        .submitLabel(.done)
                        .onSubmit { focus.wrappedValue = nil }
                }
            }
        }
        .sheet(isPresented: $isPayeePickerPresented) {
            PayeePickerView(
                title: isMultiValue ? "Choose Payees" : "Choose Payee",
                items: (options?.payees ?? []).map {
                    PayeePickerItem(id: $0.id, title: $0.name, isTransfer: $0.isTransfer)
                },
                selectedIDs: Set(isMultiValue ? selectedIDs : selectedID.map { [$0] } ?? []),
                allowsMultipleSelection: isMultiValue,
                isLoading: options == nil,
                searchPrompt: "Search payees"
            ) { id in
                value = RuleEditorDraftState.payeeValue(afterSelecting: id, current: value, isMultiValue: isMultiValue)
            }
            .appSwitcherPrivacyProtected()
        }
    }

    private var placeholder: String {
        "Value"
    }

    private var isMultiValue: Bool {
        operation == "oneOf" || operation == "notOneOf"
    }

    private var rangeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            amountInput("Minimum", binding: rangeBinding(key: "num1"), focusValue: .range(inputID, "num1"))
            amountInput("Maximum", binding: rangeBinding(key: "num2"), focusValue: .range(inputID, "num2"))
        }
    }

    @ViewBuilder
    private var dateEditor: some View {
        if RuleEditorDraftState.dateSelection(value) != nil {
            DatePicker("Value", selection: dateBinding, displayedComponents: .date)
                .accessibilityIdentifier("rule-date-picker")
        } else {
            labeledInput("Value") {
                TextField("YYYY or YYYY-MM or YYYY-MM-DD", text: stringBinding)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(focus, equals: .value(inputID))
                    .submitLabel(.done)
                    .onSubmit { focus.wrappedValue = nil }
            }
            Text("Enter a complete date to use the calendar. Year- and month-only matches keep their existing precision.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
    }

    private var amountEditor: some View {
        amountInput("Value", binding: amountBinding, focusValue: .value(inputID))
    }

    @ViewBuilder
    private var multiValueEditor: some View {
        if RuleCondition.valueKind(for: field) == .id {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(selectedIDs, id: \.self) { id in
                    HStack {
                        Text(multiValueName(for: id))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove \(multiValueName(for: id))", systemImage: "minus.circle") {
                            value = RuleEditorDraftState.removeID(id, from: value)
                        }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(ActualistTheme.danger)
                    }
                }

                if options == nil {
                    ProgressView("Loading values")
                        .controlSize(.small)
                } else if field == "payee" {
                    Button("Choose Payees", systemImage: "person.crop.circle.badge.plus") {
                        focus.wrappedValue = nil
                        isPayeePickerPresented = true
                    }
                    .buttonStyle(.plain)
                    .disabled(choices?.isEmpty != false)
                } else {
                    Menu("Add Value", systemImage: "plus") {
                        ForEach(availableMultiValueChoices, id: \.id) { choice in
                            Button(choice.name) { value = RuleEditorDraftState.appendID(choice.id, to: value) }
                        }
                        if availableMultiValueChoices.isEmpty {
                            Text("All values selected")
                        }
                    }
                    .disabled(availableMultiValueChoices.isEmpty)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(stringValues.indices, id: \.self) { index in
                    HStack {
                        TextField("Value \(index + 1)", text: stringValueBinding(at: index))
                            .textInputAutocapitalization(.never)
                            .focused(focus, equals: .listValue(inputID, index))
                            .submitLabel(.done)
                            .onSubmit { focus.wrappedValue = nil }
                        Button("Remove Value \(index + 1)", systemImage: "minus.circle") {
                            value = RuleEditorDraftState.removeStringValue(at: index, from: value)
                        }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(ActualistTheme.danger)
                    }
                }
                Button("Add Value", systemImage: "plus") {
                    value = RuleEditorDraftState.appendStringValue(to: value)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedIDs: [String] {
        RuleEditorDraftState.selectedIDs(value)
    }

    private var stringValues: [String] {
        RuleEditorDraftState.stringValues(value)
    }

    private func stringValueBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                let values = stringValues
                return values.indices.contains(index) ? values[index] : ""
            },
            set: { updated in
                var values = stringValues
                guard values.indices.contains(index) else { return }
                values[index] = updated
                value = .array(values.map(RuleJSONValue.string))
            }
        )
    }

    private var availableMultiValueChoices: [(id: String, name: String)] {
        (choices ?? []).filter { !selectedIDs.contains($0.id) }
    }

    private func multiValueName(for id: String) -> String {
        choices?.first { $0.id == id }?.name ?? RulePresentation.deletedValueName(for: field)
    }

    @ViewBuilder
    private var identifierEditor: some View {
        if options == nil {
            ProgressView("Loading value")
                .controlSize(.small)
        } else if field == "payee" {
            Button {
                focus.wrappedValue = nil
                isPayeePickerPresented = true
            } label: {
                HStack {
                    Text("Value")
                    Spacer()
                    Text(selectedPayeeName)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            RuleMenuPickerRow("Value", selection: stringBinding) {
                Text("None").tag("")
                if let selectedID, choices?.contains(where: { $0.id == selectedID }) != true {
                    Text(RulePresentation.deletedValueName(for: field)).tag(selectedID)
                }
                ForEach(choices ?? [], id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
        }
    }

    private var selectedID: String? {
        guard case .string(let id) = value, !id.isEmpty else { return nil }
        return id
    }

    private var selectedPayeeName: String {
        guard let selectedID else { return "None" }
        return choices?.first { $0.id == selectedID }?.name
            ?? RulePresentation.deletedValueName(for: field)
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { RuleEditorDraftState.editableString(value) },
            set: { text in
                value = text.isEmpty ? .null : .string(text)
            }
        )
    }

    private var amountBinding: Binding<Decimal?> {
        Binding(
            get: { RuleEditorDraftState.amountDisplayValue(value, currency: currency) },
            set: { amount in value = RuleEditorDraftState.amountValue(from: amount, currency: currency) }
        )
    }

    private func rangeBinding(key: String) -> Binding<Decimal?> {
        Binding(
            get: { RuleEditorDraftState.rangeDisplayValue(value, key: key, currency: currency) },
            set: { amount in
                value = RuleEditorDraftState.rangeValue(
                    from: amount,
                    current: value,
                    key: key,
                    currency: currency
                )
            }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                RuleEditorDraftState.dateSelection(value)
                    ?? RuleEditorDraftState.dateSelection(RuleEditorDraftState.defaultValue(for: .date))
                    ?? Date()
            },
            set: { value = RuleEditorDraftState.dateValue(from: $0) }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { if case .bool(let current) = value { current } else { false } },
            set: { value = .bool($0) }
        )
    }

    private var choices: [(id: String, name: String)]? {
        guard let options else { return nil }
        switch field {
        case "account": return options.accounts.map { ($0.id, $0.name) }
        case "category": return options.categories.map { ($0.id, $0.name) }
        case "category_group": return options.categoryGroups.map { ($0.id, $0.name) }
        case "payee": return options.payees.map { ($0.id, $0.name) }
        default: return nil
        }
    }

    private func amountInput(
        _ title: String,
        binding: Binding<Decimal?>,
        focusValue: RuleEditorFocus
    ) -> some View {
        labeledInput(title) {
            TextField(
                title,
                value: binding,
                format: BudgetMoneyInputFormat(currency: currency, locale: locale)
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.leading)
            .focused(focus, equals: focusValue)
            .submitLabel(.done)
            .onSubmit { focus.wrappedValue = nil }
        }
    }

    private func labeledInput<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
