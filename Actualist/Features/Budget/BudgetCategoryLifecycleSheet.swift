import Observation
import SwiftUI

enum BudgetCategoryLifecycleSheet: Identifiable, Equatable {
    case createCategory(groups: [BudgetMonthCategoryGroup], isTrackingBudget: Bool)
    case createGroup
    case renameCategory(BudgetMonthCategory, isTrackingBudget: Bool)
    case renameGroup(BudgetMonthCategoryGroup, isTrackingBudget: Bool)
    case reorder(groups: [BudgetMonthCategoryGroup], isTrackingBudget: Bool)

    var id: String {
        switch self {
        case .createCategory: "create-category"
        case .createGroup: "create-group"
        case .renameCategory(let category, _): "rename-category:\(category.id)"
        case .renameGroup(let group, _): "rename-group:\(group.id)"
        case .reorder: "reorder"
        }
    }

    var title: String {
        switch self {
        case .createCategory: "New Category"
        case .createGroup: "New Group"
        case .renameCategory: "Rename Category"
        case .renameGroup: "Rename Group"
        case .reorder: "Reorder Categories"
        }
    }
}

@MainActor
@Observable
final class BudgetCategoryLifecycleController {
    let organization = BudgetCategoryOrganizationWorkflow()
    let reorder = BudgetCategoryReorderWorkflow()

    var errorMessage: String? {
        organization.errorMessage ?? reorder.errorMessage
    }

    var isSubmitting: Bool {
        organization.isSubmitting || reorder.isSubmitting
    }

    static func manageableGroups(
        _ groups: [BudgetMonthCategoryGroup],
        isTrackingBudget: Bool
    ) -> [BudgetMonthCategoryGroup] {
        isTrackingBudget ? groups : groups.filter { !$0.isIncome }
    }

    func prepare(_ sheet: BudgetCategoryLifecycleSheet) {
        organization.cancel()
        reorder.cancel()
        if case .reorder(let groups, let isTrackingBudget) = sheet {
            reorder.begin(groups: groups, isTrackingBudget: isTrackingBudget)
        }
    }

    func cancel() {
        organization.cancel()
        reorder.cancel()
    }

    func submitName(
        _ name: String,
        selectedGroupID: String?,
        sheet: BudgetCategoryLifecycleSheet,
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        switch sheet {
        case .createCategory(let groups, let isTrackingBudget):
            guard let group = groups.first(where: { $0.id == selectedGroupID }) else { return false }
            return await organization.createCategory(
                name: name,
                group: group,
                isTrackingBudget: isTrackingBudget,
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) != nil
        case .createGroup:
            return await organization.createGroup(
                name: name,
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) != nil
        case .renameCategory(let category, let isTrackingBudget):
            if name.trimmingCharacters(in: .whitespacesAndNewlines) == category.name { return true }
            return await organization.renameCategory(
                category,
                name: name,
                isTrackingBudget: isTrackingBudget,
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) != nil
        case .renameGroup(let group, let isTrackingBudget):
            if name.trimmingCharacters(in: .whitespacesAndNewlines) == group.name { return true }
            return await organization.renameGroup(
                group,
                name: name,
                isTrackingBudget: isTrackingBudget,
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) != nil
        case .reorder:
            return false
        }
    }

    func saveReorder(
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        if reorder.draft?.command == nil { return true }
        return await reorder.save(
            selectedMonth: selectedMonth,
            budgetID: budgetID,
            repository: repository
        ) != nil
    }
}

struct BudgetCategoryNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: BudgetCategoryLifecycleController
    let sheet: BudgetCategoryLifecycleSheet
    let selectedMonth: String?
    let budgetID: String?
    let repository: any BudgetRepositoryProtocol
    let onSaved: @MainActor () async -> Void

    @State private var name: String
    @State private var selectedGroupID: String?

    init(
        controller: BudgetCategoryLifecycleController,
        sheet: BudgetCategoryLifecycleSheet,
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol,
        onSaved: @escaping @MainActor () async -> Void
    ) {
        self.controller = controller
        self.sheet = sheet
        self.selectedMonth = selectedMonth
        self.budgetID = budgetID
        self.repository = repository
        self.onSaved = onSaved
        switch sheet {
        case .createCategory(let groups, let isTrackingBudget):
            let choices = BudgetCategoryLifecycleController.manageableGroups(
                groups,
                isTrackingBudget: isTrackingBudget
            )
            _name = State(initialValue: "")
            _selectedGroupID = State(initialValue: choices.first?.id)
        case .createGroup:
            _name = State(initialValue: "")
            _selectedGroupID = State(initialValue: nil)
        case .renameCategory(let category, _):
            _name = State(initialValue: category.name)
            _selectedGroupID = State(initialValue: nil)
        case .renameGroup(let group, _):
            _name = State(initialValue: group.name)
            _selectedGroupID = State(initialValue: nil)
        case .reorder:
            _name = State(initialValue: "")
            _selectedGroupID = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(nameFieldLabel, text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("budget-category-lifecycle-name")
                }

                if !categoryGroupChoices.isEmpty {
                    Section("Group") {
                        Picker("Group", selection: $selectedGroupID) {
                            ForEach(categoryGroupChoices) { group in
                                Text(group.hidden == true ? "\(group.name) (Hidden)" : group.name)
                                    .tag(Optional(group.id))
                            }
                        }
                        .accessibilityIdentifier("budget-category-lifecycle-group")
                    }
                }

                if let errorMessage = controller.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(ActualistTheme.danger)
                            .accessibilityIdentifier("budget-category-lifecycle-error")
                    }
                }
            }
            .accessibilityIdentifier("budget-category-lifecycle-name-sheet")
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) { submit() }
                        .disabled(controller.isSubmitting || requiresGroup && selectedGroupID == nil)
                        .accessibilityIdentifier("budget-category-lifecycle-save")
                }
            }
        }
        .interactiveDismissDisabled(controller.isSubmitting)
    }

    private var categoryGroupChoices: [BudgetMonthCategoryGroup] {
        guard case .createCategory(let groups, let isTrackingBudget) = sheet else { return [] }
        return BudgetCategoryLifecycleController.manageableGroups(
            groups,
            isTrackingBudget: isTrackingBudget
        )
    }

    private var requiresGroup: Bool {
        if case .createCategory = sheet { return true }
        return false
    }

    private var nameFieldLabel: String {
        switch sheet {
        case .createCategory, .renameCategory: "Category Name"
        case .createGroup, .renameGroup: "Group Name"
        case .reorder: "Name"
        }
    }

    private var saveTitle: String {
        switch sheet {
        case .createCategory, .createGroup: "Add"
        case .renameCategory, .renameGroup, .reorder: "Save"
        }
    }

    private func submit() {
        Task {
            guard await controller.submitName(
                name,
                selectedGroupID: selectedGroupID,
                sheet: sheet,
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) else { return }
            await onSaved()
            dismiss()
        }
    }

}
