import Observation
import SwiftUI

@MainActor
@Observable
final class PayeeRulesViewModel {
    var rules: [ManagedRule] = []
    var options: RuleEditorOptions?
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?

    func load(payeeID: String, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        if let cached = appState.ruleRepository.cachedRules(budgetID: budgetID) {
            rules = cached.filter { $0.payeeIDs.contains(payeeID) && !$0.isCompletedScheduleRule }
        }
        isLoading = rules.isEmpty
        options = try? await appState.ruleRepository.ruleEditorOptions(budgetID: budgetID)
        do {
            try await appState.ruleRepository.refreshRules(budgetID: budgetID)
            rules = (appState.ruleRepository.cachedRules(budgetID: budgetID) ?? [])
                .filter { $0.payeeIDs.contains(payeeID) && !$0.isCompletedScheduleRule }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func save(ruleID: String?, draft: RuleDraft, payeeID: String, using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if let ruleID {
                try await appState.ruleRepository.updateRuleAndRefresh(
                    budgetID: budgetID,
                    ruleID: ruleID,
                    draft: draft
                )
            } else {
                try await appState.ruleRepository.createRuleAndRefresh(budgetID: budgetID, draft: draft)
            }
            rules = (appState.ruleRepository.cachedRules(budgetID: budgetID) ?? [])
                .filter { $0.payeeIDs.contains(payeeID) && !$0.isCompletedScheduleRule }
            appState.recordLocalDataMutation()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(ruleID: String, payeeID: String, using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await appState.ruleRepository.deleteRuleAndRefresh(budgetID: budgetID, ruleID: ruleID)
            rules = (appState.ruleRepository.cachedRules(budgetID: budgetID) ?? [])
                .filter { $0.payeeIDs.contains(payeeID) && !$0.isCompletedScheduleRule }
            appState.recordLocalDataMutation()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct PayeeRulesView: View {
    @Environment(AppState.self) private var appState
    let payee: ManagedPayee
    @State private var viewModel = PayeeRulesViewModel()
    @State private var editorTarget: RuleEditorTarget?
    @State private var pendingDeleteRule: ManagedRule?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
                    .settingsRowChrome()
            }

            Section {
                if viewModel.isLoading && viewModel.rules.isEmpty {
                    ProgressView("Loading rules")
                } else if viewModel.rules.isEmpty {
                    ContentUnavailableView(
                        "No Rules",
                        systemImage: "wand.and.stars",
                        description: Text("Create a rule that applies whenever this payee is used.")
                    )
                } else {
                    ForEach(viewModel.rules) { rule in
                        Button {
                            editorTarget = RuleEditorTarget(rule: rule, fallbackPayeeID: payee.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rule.isScheduleOwned ? "Schedule · Read-only" : rule.draft?.stage.displayName ?? "Read-only")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                Text(rule.summary(options: viewModel.options))
                                    .foregroundStyle(ActualistTheme.primaryText)
                                    .multilineTextAlignment(.leading)
                                if !rule.isEditable {
                                    Label(
                                        rule.isScheduleOwned
                                            ? "Managed by an Actual schedule"
                                            : "Contains fields this version cannot safely edit",
                                        systemImage: "lock.fill"
                                    )
                                        .font(.caption2)
                                        .foregroundStyle(ActualistTheme.warning)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !rule.isScheduleOwned {
                                Button("Delete") { pendingDeleteRule = rule }
                                    .tint(ActualistTheme.danger)
                            }
                        }
                    }
                }
            } header: {
                Text(payee.isTransfer ? "Transfer Rules" : "Associated Rules")
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = RuleEditorTarget(rule: nil, fallbackPayeeID: payee.id)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Rule")
                .disabled(viewModel.isSubmitting)
            }
        }
        .task { await viewModel.load(payeeID: payee.id, using: appState) }
        .refreshable { await viewModel.load(payeeID: payee.id, using: appState) }
        .sheet(item: $editorTarget) { target in
            RuleEditorView(
                target: target,
                isSubmitting: viewModel.isSubmitting,
                errorMessage: viewModel.errorMessage
            ) { draft in
                await viewModel.save(
                    ruleID: target.rule?.id,
                    draft: draft,
                    payeeID: payee.id,
                    using: appState
                )
            }
            .appSwitcherPrivacyAwareDragIndicator()
            .appSwitcherPrivacyProtected()
        }
        .confirmationDialog(
            "Delete Rule?",
            isPresented: Binding(
                get: { pendingDeleteRule != nil },
                set: { if !$0 { pendingDeleteRule = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let rule = pendingDeleteRule {
                Button("Delete Rule", role: .destructive) {
                    pendingDeleteRule = nil
                    Task { _ = await viewModel.delete(ruleID: rule.id, payeeID: payee.id, using: appState) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteRule = nil }
        } message: {
            Text("Future transactions will no longer be processed by this rule.")
        }
    }
}

struct RuleEditorTarget: Identifiable {
    let id = UUID()
    let rule: ManagedRule?
    let fallbackPayeeID: String

    var initialDraft: RuleDraft {
        rule?.draft ?? .categoryRule(payeeID: fallbackPayeeID)
    }
}

private struct RuleEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let target: RuleEditorTarget
    let isSubmitting: Bool
    let errorMessage: String?
    let onSave: (RuleDraft) async -> Bool
    @State private var viewModel: RuleEditorViewModel

    init(
        target: RuleEditorTarget,
        isSubmitting: Bool,
        errorMessage: String?,
        onSave: @escaping (RuleDraft) async -> Bool
    ) {
        self.target = target
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.onSave = onSave
        _viewModel = State(initialValue: RuleEditorViewModel(draft: target.initialDraft))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                if target.rule?.isEditable == false {
                    Section {
                        ForEach(
                            Array((target.rule?.readOnlyDetails(options: viewModel.options) ?? []).enumerated()),
                            id: \.offset
                        ) { _, detail in
                            Text(detail)
                        }
                    } header: {
                        Text("Read-only rule")
                    } footer: {
                        Text(
                            target.rule?.isScheduleOwned == true
                                ? "This rule is managed by an Actual schedule. It cannot be edited or deleted here."
                                : "This rule contains data Actualist cannot round-trip safely. It can still be deleted."
                        )
                    }
                } else {
                    Section("Order") {
                        RuleMenuPickerRow("Stage", selection: $viewModel.draft.stage) {
                            ForEach(RuleStage.allCases) { stage in
                                Text(stage.displayName).tag(stage)
                            }
                        }
                        RuleMenuPickerRow("Match", selection: $viewModel.draft.conditionsJoin) {
                            ForEach(RuleConditionJoin.allCases) { join in
                                Text(join == .and ? "All conditions" : "Any condition").tag(join)
                            }
                        }
                    }
                    .settingsSectionChrome()

                    Section("Conditions") {
                        ForEach($viewModel.draft.conditions) { $condition in
                            RuleConditionEditor(condition: $condition, options: viewModel.options)
                        }
                        .onDelete { viewModel.draft.conditions.remove(atOffsets: $0) }
                        Button("Add Condition", systemImage: "plus") {
                            viewModel.draft.conditions.append(
                                RuleCondition(field: "description", operation: "is", value: .string(target.fallbackPayeeID), type: "id")
                            )
                        }
                    }
                    .settingsSectionChrome()

                    Section("Actions") {
                        ForEach($viewModel.draft.actions) { $action in
                            RuleActionEditor(action: $action, options: viewModel.options)
                        }
                        .onDelete { viewModel.draft.actions.remove(atOffsets: $0) }
                        Button("Add Action", systemImage: "plus") {
                            viewModel.draft.actions.append(RuleAction(operation: "set", field: "category", value: .null, type: "id"))
                        }
                    }
                    .settingsSectionChrome()

                    matchingTransactionsSection
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle(target.rule == nil ? "New Rule" : target.rule?.isEditable == false ? "View Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if target.rule?.isEditable != false {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { if await onSave(viewModel.draft) { dismiss() } }
                        }
                        .disabled(!viewModel.draft.canRoundTripAndEvaluate || isSubmitting)
                    }
                }
            }
            .task {
                await viewModel.load(using: appState)
            }
            .onChange(of: viewModel.draft) {
                viewModel.scheduleMatchRefresh(using: appState)
            }
            .onDisappear {
                viewModel.cancelMatchRefresh()
            }
        }
    }

    @ViewBuilder
    private var matchingTransactionsSection: some View {
        Section {
            if viewModel.isLoadingMatches && viewModel.matchPreview == nil {
                ProgressView("Finding matching transactions")
            } else if let matchErrorMessage = viewModel.matchErrorMessage {
                Text(matchErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
            } else if viewModel.matchPreview?.totalCount == 0 {
                ContentUnavailableView(
                    "No Matching Transactions",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No existing transactions match these conditions.")
                )
            } else if let preview = viewModel.matchPreview {
                ForEach(preview.transactions) { transaction in
                    RuleTransactionMatchRow(transaction: transaction)
                }
            }
        } header: {
            HStack {
                Text("This rule applies to the following transactions")
                Spacer()
                if let count = viewModel.matchPreview?.totalCount {
                    Text(count.formatted())
                }
            }
        } footer: {
            if let preview = viewModel.matchPreview,
               preview.totalCount > preview.transactions.count {
                Text("Showing the newest \(preview.transactions.count) of \(preview.totalCount) matches.")
            }
        }
        .settingsSectionChrome()
    }
}

private struct RuleMenuPickerRow<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let content: () -> Content

    init(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: $selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(title)
        }
    }
}

private struct RuleConditionEditor: View {
    @Binding var condition: RuleCondition
    let options: RuleEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RuleMenuPickerRow("Field", selection: editorFieldBinding) {
                ForEach(RuleCondition.editableFields, id: \.value) { Text($0.name).tag($0.value) }
            }
            RuleMenuPickerRow("Comparison", selection: $condition.operation) {
                ForEach(operations, id: \.self) { Text(RulePresentation.operationName($0)).tag($0) }
            }
            if condition.operation != "onBudget" && condition.operation != "offBudget" {
                RuleValueEditor(value: $condition.value, field: condition.editorField, operation: condition.operation, options: options)
            }
        }
        .onChange(of: condition.operation) {
            normalizeValueForOperation()
        }
    }

    private var operations: [String] { RuleCondition.operations(for: condition.editorField) }

    private var editorFieldBinding: Binding<String> {
        Binding(
            get: { condition.editorField },
            set: { newField in
                let previousField = condition.editorField
                let newKind = RuleCondition.valueKind(for: newField)
                condition.field = RuleCondition.serializedField(newField)
                condition.options = RuleCondition.options(for: newField)
                condition.type = newKind?.rawValue
                if previousField != newField {
                    condition.operation = RuleCondition.operations(for: newField).first ?? "is"
                    condition.value = defaultValue(for: newKind)
                } else if !RuleCondition.operations(for: newField).contains(condition.operation) {
                    condition.operation = RuleCondition.operations(for: newField).first ?? "is"
                }
            }
        )
    }

    private func defaultValue(for kind: RuleCondition.ValueKind?) -> RuleJSONValue {
        switch kind {
        case .boolean: .bool(false)
        case .number: .number(0)
        case .date: .string(Self.dateFormatter.string(from: Date()))
        case .string: .string("")
        case .id, nil: .null
        }
    }

    private func normalizeValueForOperation() {
        if condition.operation == "onBudget" || condition.operation == "offBudget" {
            condition.value = .null
        } else if condition.operation == "oneOf" || condition.operation == "notOneOf" {
            if case .array = condition.value { return }
            condition.value = condition.value == .null ? .array([]) : .array([condition.value])
        } else if case .array(let values) = condition.value {
            condition.value = values.first ?? defaultValue(for: RuleCondition.valueKind(for: condition.field))
        } else if condition.operation == "isbetween" {
            let initial = condition.value.isNumberLike ? condition.value : .number(0)
            condition.value = .object(["num1": initial, "num2": initial])
        } else if case .object(let range) = condition.value {
            condition.value = range["num1"] ?? .number(0)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

}

private struct RuleActionEditor: View {
    @Binding var action: RuleAction
    let options: RuleEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RuleMenuPickerRow("Action", selection: $action.operation) {
                Text("Set field").tag("set")
                Text("Prepend notes").tag("prepend-notes")
                Text("Append notes").tag("append-notes")
            }
            if action.operation == "set" {
                RuleMenuPickerRow("Field", selection: actionFieldBinding) {
                    ForEach(["account", "amount", "category", "date", "notes", "payee", "cleared"], id: \.self) {
                        Text(RulePresentation.fieldName($0)).tag($0)
                    }
                }
            }
            RuleValueEditor(
                value: $action.value,
                field: action.editorField ?? action.operation,
                operation: action.operation,
                options: options
            )
        }
        .onChange(of: action.operation) {
            if action.operation == "set" {
                if action.field == nil {
                    action.field = "category"
                    action.type = RuleCondition.ValueKind.id.rawValue
                    action.value = .null
                }
            } else {
                let needsStringValue: Bool
                if case .string = action.value {
                    needsStringValue = false
                } else {
                    needsStringValue = true
                }
                action.field = nil
                action.type = RuleCondition.ValueKind.string.rawValue
                if needsStringValue {
                    action.value = .string("")
                }
            }
        }
    }

    private var actionFieldBinding: Binding<String> {
        Binding(
            get: { action.editorField ?? "category" },
            set: { newField in
                guard action.editorField != newField else { return }
                let kind = RuleCondition.valueKind(for: newField)
                action.field = RuleCondition.serializedField(newField)
                action.type = kind?.rawValue
                action.value = defaultValue(for: kind)
            }
        )
    }

    private func defaultValue(for kind: RuleCondition.ValueKind?) -> RuleJSONValue {
        switch kind {
        case .boolean: .bool(false)
        case .number: .number(0)
        case .date: .string(Self.dateFormatter.string(from: Date()))
        case .string: .string("")
        case .id, nil: .null
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct RuleValueEditor: View {
    @Binding var value: RuleJSONValue
    let field: String
    let operation: String
    let options: RuleEditorOptions?
    @State private var isPayeePickerPresented = false

    var body: some View {
        Group {
            if operation == "isbetween" {
                HStack {
                    TextField("Minimum", text: rangeBinding(key: "num1"))
                        .keyboardType(.decimalPad)
                    Text("and")
                        .foregroundStyle(ActualistTheme.secondaryText)
                    TextField("Maximum", text: rangeBinding(key: "num2"))
                        .keyboardType(.decimalPad)
                }
            } else if ["cleared", "reconciled", "transfer", "parent"].contains(field) {
                RuleMenuPickerRow("Value", selection: boolBinding) {
                    Text("Yes").tag(true)
                    Text("No").tag(false)
                }
            } else if isMultiValue {
                multiValueEditor
            } else if RuleCondition.valueKind(for: field) == .id {
                identifierEditor
            } else {
                TextField(placeholder, text: stringBinding)
                    .textInputAutocapitalization(field == "notes" ? .sentences : .never)
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
                selectPayee(id)
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

    @ViewBuilder
    private var multiValueEditor: some View {
        if RuleCondition.valueKind(for: field) == .id {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(selectedIDs, id: \.self) { id in
                    HStack {
                        Text(multiValueName(for: id))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove \(multiValueName(for: id))", systemImage: "minus.circle") {
                            removeID(id)
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
                        isPayeePickerPresented = true
                    }
                    .buttonStyle(.plain)
                    .disabled(choices?.isEmpty != false)
                } else {
                    Menu("Add Value", systemImage: "plus") {
                        ForEach(availableMultiValueChoices, id: \.id) { choice in
                            Button(choice.name) { appendID(choice.id) }
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
                        Button("Remove Value \(index + 1)", systemImage: "minus.circle") {
                            removeStringValue(at: index)
                        }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(ActualistTheme.danger)
                    }
                }
                Button("Add Value", systemImage: "plus") {
                    appendStringValue()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedIDs: [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { item in
            if case .string(let id) = item { return id }
            return nil
        }
    }

    private var stringValues: [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { item in
            if case .string(let text) = item { return text }
            return nil
        }
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

    private func selectPayee(_ id: String) {
        if isMultiValue {
            if selectedIDs.contains(id) {
                removeID(id)
            } else {
                appendID(id)
            }
        } else {
            value = .string(id)
        }
    }

    private func appendID(_ id: String) {
        var ids = selectedIDs
        guard !ids.contains(id) else { return }
        ids.append(id)
        value = .array(ids.map(RuleJSONValue.string))
    }

    private func removeID(_ id: String) {
        var ids = selectedIDs
        ids.removeAll { $0 == id }
        value = .array(ids.map(RuleJSONValue.string))
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

    private func appendStringValue() {
        var values = stringValues
        values.append("")
        value = .array(values.map(RuleJSONValue.string))
    }

    private func removeStringValue(at index: Int) {
        var values = stringValues
        guard values.indices.contains(index) else { return }
        values.remove(at: index)
        value = .array(values.map(RuleJSONValue.string))
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { field == "amount" ? amountDisplayText(value) : editableString(value) },
            set: { text in
                if field == "amount", let number = Decimal(string: text) {
                    value = .number(NSDecimalNumber(decimal: number * 100).doubleValue)
                } else {
                    value = text.isEmpty ? .null : .string(text)
                }
            }
        )
    }

    private func rangeBinding(key: String) -> Binding<String> {
        Binding(
            get: {
                guard case .object(let range) = value, let raw = range[key] else { return "" }
                return amountDisplayText(raw)
            },
            set: { text in
                var range: [String: RuleJSONValue]
                if case .object(let current) = value { range = current } else { range = [:] }
                if let number = Decimal(string: text) {
                    range[key] = .number(NSDecimalNumber(decimal: number * 100).doubleValue)
                } else {
                    range[key] = .number(0)
                }
                value = .object(range)
            }
        )
    }

    private func amountDisplayText(_ raw: RuleJSONValue) -> String {
        let number: Double
        switch raw {
        case .number(let stored): number = stored
        case .string(let stored):
            guard let parsed = Double(stored) else { return "" }
            number = parsed
        default: return ""
        }
        return editableNumber(number / 100)
    }

    private func editableString(_ raw: RuleJSONValue) -> String {
        switch raw {
        case .string(let text): text
        case .number(let number): editableNumber(number)
        case .null: ""
        case .bool, .array, .object: ""
        }
    }

    private func editableNumber(_ number: Double) -> String {
        guard number.isFinite else { return "" }
        if number.rounded() == number,
           number >= Double(Int.min),
           number <= Double(Int.max) {
            return String(Int(number))
        }
        return String(number)
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

}
