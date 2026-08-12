import Observation
import SwiftUI

@MainActor
@Observable
final class PayeeRulesViewModel {
    var rules: [ManagedRule] = []
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?

    func load(payeeID: String, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        if let cached = appState.ruleRepository.cachedRules(budgetID: budgetID) {
            rules = cached.filter { $0.payeeIDs.contains(payeeID) && !$0.isCompletedScheduleRule }
        }
        isLoading = rules.isEmpty
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
                                Text(rule.draft?.stage.displayName ?? "Read-only")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                Text(rule.summary)
                                    .foregroundStyle(ActualistTheme.primaryText)
                                    .multilineTextAlignment(.leading)
                                if !rule.isEditable {
                                    Label("Contains fields this version cannot safely edit", systemImage: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(ActualistTheme.warning)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete") { pendingDeleteRule = rule }
                                .tint(ActualistTheme.danger)
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
    @State private var draft: RuleDraft
    @State private var options: TransactionEditorOptions?

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
        _draft = State(initialValue: target.initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if target.rule?.isEditable == false {
                    Section {
                        Text(target.rule?.rawConditionsJSON ?? "")
                            .font(.caption.monospaced())
                        Text(target.rule?.rawActionsJSON ?? "")
                            .font(.caption.monospaced())
                    } header: {
                        Text("Read-only rule data")
                    } footer: {
                        Text("This rule contains data Actualist cannot round-trip safely. It can still be deleted.")
                    }
                } else {
                    Section("Order") {
                        Picker("Stage", selection: $draft.stage) {
                            ForEach(RuleStage.allCases) { stage in
                                Text(stage.displayName).tag(stage)
                            }
                        }
                        Picker("Match", selection: $draft.conditionsJoin) {
                            ForEach(RuleConditionJoin.allCases) { join in
                                Text(join == .and ? "All conditions" : "Any condition").tag(join)
                            }
                        }
                    }
                    .settingsSectionChrome()

                    Section("Conditions") {
                        ForEach($draft.conditions) { $condition in
                            RuleConditionEditor(condition: $condition, options: options)
                        }
                        .onDelete { draft.conditions.remove(atOffsets: $0) }
                        Button("Add Condition", systemImage: "plus") {
                            draft.conditions.append(
                                RuleCondition(field: "payee", operation: "is", value: .string(target.fallbackPayeeID), type: "id")
                            )
                        }
                    }
                    .settingsSectionChrome()

                    Section("Actions") {
                        ForEach($draft.actions) { $action in
                            RuleActionEditor(action: $action, options: options)
                        }
                        .onDelete { draft.actions.remove(atOffsets: $0) }
                        Button("Add Action", systemImage: "plus") {
                            draft.actions.append(RuleAction(operation: "set", field: "category", value: .null, type: "id"))
                        }
                    }
                    .settingsSectionChrome()
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
            .navigationTitle(target.rule == nil ? "New Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if target.rule?.isEditable != false {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { if await onSave(draft) { dismiss() } }
                        }
                        .disabled(draft.conditions.isEmpty || draft.actions.isEmpty || isSubmitting)
                    }
                }
            }
            .task {
                guard let budgetID = appState.settings.selectedBudgetID else { return }
                options = try? await appState.transactionRepository.editorOptions(
                    budgetID: budgetID,
                    month: Self.currentMonth
                )
            }
        }
    }

    private static var currentMonth: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }
}

private struct RuleConditionEditor: View {
    @Binding var condition: RuleCondition
    let options: TransactionEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Field", selection: $condition.field) {
                ForEach(Self.fields, id: \.value) { Text($0.name).tag($0.value) }
            }
            Picker("Comparison", selection: $condition.operation) {
                ForEach(operations, id: \.self) { Text(Self.operationName($0)).tag($0) }
            }
            if condition.operation != "onBudget" && condition.operation != "offBudget" {
                RuleValueEditor(value: $condition.value, field: condition.field, operation: condition.operation, options: options)
            }
        }
        .onChange(of: condition.field) {
            condition.operation = Self.operations(for: condition.field).first ?? "is"
            condition.type = Self.idFields.contains(condition.field) ? "id" : nil
        }
        .onChange(of: condition.operation) {
            if condition.operation == "isbetween" {
                condition.value = .object(["num1": .number(0), "num2": .number(0)])
            } else if case .object = condition.value {
                condition.value = .number(0)
            }
        }
    }

    private var operations: [String] { Self.operations(for: condition.field) }
    private static let idFields: Set<String> = ["account", "category", "category_group", "payee"]
    private static let fields = [
        ("Account", "account"), ("Amount", "amount"), ("Category", "category"),
        ("Category Group", "category_group"), ("Date", "date"), ("Notes", "notes"),
        ("Payee", "payee"), ("Cleared", "cleared"),
        ("Transfer", "transfer")
    ].map { (name: $0.0, value: $0.1) }

    private static func operations(for field: String) -> [String] {
        switch field {
        case "account": ["is", "isNot", "oneOf", "notOneOf", "contains", "doesNotContain", "matches", "onBudget", "offBudget"]
        case "amount": ["is", "isapprox", "isbetween", "gt", "gte", "lt", "lte"]
        case "date": ["is", "isapprox", "gt", "gte", "lt", "lte"]
        case "cleared", "transfer": ["is"]
        case "notes": ["is", "isNot", "contains", "doesNotContain", "matches", "hasTags", "hasAnyTag"]
        default: ["is", "isNot", "oneOf", "notOneOf", "contains", "doesNotContain", "matches"]
        }
    }

    private static func operationName(_ operation: String) -> String {
        switch operation {
        case "isNot": "Is not"
        case "oneOf": "Is one of"
        case "notOneOf": "Is not one of"
        case "doesNotContain": "Does not contain"
        case "isapprox": "Is approximately"
        case "isbetween": "Is between"
        case "gt": "Is greater than"
        case "gte": "Is at least"
        case "lt": "Is less than"
        case "lte": "Is at most"
        case "hasTags": "Has all tags"
        case "hasAnyTag": "Has any tag"
        default: operation.capitalized
        }
    }
}

private struct RuleActionEditor: View {
    @Binding var action: RuleAction
    let options: TransactionEditorOptions?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $action.operation) {
                Text("Set field").tag("set")
                Text("Prepend notes").tag("prepend-notes")
                Text("Append notes").tag("append-notes")
            }
            if action.operation == "set" {
                Picker("Field", selection: Binding(
                    get: { action.field ?? "category" },
                    set: { action.field = $0 }
                )) {
                    ForEach(["account", "amount", "category", "date", "notes", "payee", "cleared"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
            }
            RuleValueEditor(
                value: $action.value,
                field: action.field ?? action.operation,
                operation: action.operation,
                options: options
            )
        }
        .onChange(of: action.operation) {
            if action.operation != "set" { action.field = nil }
        }
    }
}

private struct RuleValueEditor: View {
    @Binding var value: RuleJSONValue
    let field: String
    let operation: String
    let options: TransactionEditorOptions?

    var body: some View {
        if operation == "isbetween" {
            HStack {
                TextField("Minimum", text: rangeBinding(key: "num1"))
                    .keyboardType(.decimalPad)
                Text("and")
                    .foregroundStyle(ActualistTheme.secondaryText)
                TextField("Maximum", text: rangeBinding(key: "num2"))
                    .keyboardType(.decimalPad)
            }
        } else if ["cleared", "transfer"].contains(field) {
            Picker("Value", selection: boolBinding) {
                Text("Yes").tag(true)
                Text("No").tag(false)
            }
        } else if let choices = choices, !choices.isEmpty, !Self.freeTextOperations.contains(operation) {
            Picker("Value", selection: stringBinding) {
                Text("None").tag("")
                ForEach(choices, id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
        } else {
            TextField(placeholder, text: stringBinding)
                .textInputAutocapitalization(field == "notes" ? .sentences : .never)
        }
    }

    private var placeholder: String {
        operation == "oneOf" || operation == "notOneOf" ? "Comma-separated values" : "Value"
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { field == "amount" ? amountDisplayText(value) : value.editableText },
            set: { text in
                if operation == "oneOf" || operation == "notOneOf" {
                    value = .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
                } else if field == "amount", let number = Decimal(string: text) {
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
        guard case .number(let number) = raw else { return raw.editableText }
        return RuleJSONValue.number(number / 100).editableText
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
        case "category": return options.categories.compactMap { category in category.id.map { ($0, category.name.actualistCategoryNameParts.name) } }
        case "category_group": return options.categoryGroups.map { ($0.id, $0.name) }
        case "payee": return options.payees.compactMap { payee in payee.id.map { ($0, payee.name) } }
        default: return nil
        }
    }

    private static let freeTextOperations: Set<String> = ["oneOf", "notOneOf", "contains", "doesNotContain", "matches"]
}
