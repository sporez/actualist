import SwiftUI

struct BudgetCategoryReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: BudgetCategoryLifecycleController
    let selectedMonth: String?
    let budgetID: String?
    let repository: any BudgetRepositoryProtocol
    let onSaved: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            List {
                if let draft = controller.reorder.draft {
                    ForEach(draft.groups) { group in
                        Section {
                            ForEach(group.categories) { category in
                                categoryRow(category, groupID: group.id)
                            }
                            dropArea(after: group)
                        } header: {
                            groupRow(group)
                        }
                        .settingsSectionChrome()
                    }
                }

                if let errorMessage = controller.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(ActualistTheme.danger)
                        .accessibilityIdentifier("budget-category-reorder-error")
                        .settingsRowChrome()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .accessibilityIdentifier("budget-category-reorder-sheet")
            .navigationTitle("Reorder Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .disabled(controller.isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(controller.isSubmitting)
                        .accessibilityIdentifier("budget-category-reorder-save")
                }
            }
        }
        .interactiveDismissDisabled(controller.isSubmitting)
    }

    private func groupRow(_ group: BudgetCategoryOutlineDraft.Group) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(group.name)
                .font(.headline)
            if group.hidden {
                Image(systemName: "eye.slash")
                    .accessibilityLabel("Hidden")
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .foregroundStyle(ActualistTheme.primaryText)
        .opacity(group.hidden ? BudgetLayout.hiddenCategoryOpacity : 1)
        .accessibilityIdentifier("budget-category-reorder-group-\(group.id)")
        .draggable(DragToken.group(group.id))
        .dropDestination(for: String.self) { tokens, _ in
            apply(tokens, toGroupID: group.id, beforeCategoryID: nil, beforeGroupID: group.id)
        }
    }

    private func categoryRow(
        _ category: BudgetCategoryOutlineDraft.Category,
        groupID: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(category.name.actualistCategoryNameParts.name)
            if category.hidden {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .accessibilityLabel("Hidden")
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .opacity(category.hidden ? BudgetLayout.hiddenCategoryOpacity : 1)
        .accessibilityIdentifier("budget-category-reorder-category-\(category.id)")
        .draggable(DragToken.category(category.id))
        .dropDestination(for: String.self) { tokens, _ in
            apply(tokens, toGroupID: groupID, beforeCategoryID: category.id, beforeGroupID: groupID)
        }
    }

    private func dropArea(after group: BudgetCategoryOutlineDraft.Group) -> some View {
        Color.clear
            .frame(height: 10)
            .accessibilityHidden(true)
            .dropDestination(for: String.self) { tokens, _ in
                apply(
                    tokens,
                    toGroupID: group.id,
                    beforeCategoryID: nil,
                    beforeGroupID: nextGroupID(after: group)
                )
            }
    }

    private func apply(
        _ tokens: [String],
        toGroupID: String,
        beforeCategoryID: String?,
        beforeGroupID: String?
    ) {
        guard let token = tokens.first else { return }
        if let categoryID = DragToken.categoryID(token) {
            controller.reorder.moveCategory(
                id: categoryID,
                toGroupID: toGroupID,
                beforeCategoryID: beforeCategoryID
            )
            return
        }
        if let groupID = DragToken.groupID(token) {
            controller.reorder.moveGroup(id: groupID, beforeGroupID: beforeGroupID)
        }
    }

    private func nextGroupID(after group: BudgetCategoryOutlineDraft.Group) -> String? {
        guard let groups = controller.reorder.draft?.groups,
              let index = groups.firstIndex(where: { $0.id == group.id }) else { return nil }
        return groups.dropFirst(index + 1).first(where: { $0.isIncome == group.isIncome })?.id
    }

    private func save() {
        Task {
            guard await controller.saveReorder(
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) else { return }
            await onSaved()
            dismiss()
        }
    }

    private enum DragToken {
        static func category(_ id: String) -> String { "category:\(id)" }
        static func group(_ id: String) -> String { "group:\(id)" }

        static func categoryID(_ token: String) -> String? {
            token.hasPrefix("category:") ? String(token.dropFirst("category:".count)) : nil
        }

        static func groupID(_ token: String) -> String? {
            token.hasPrefix("group:") ? String(token.dropFirst("group:".count)) : nil
        }
    }
}
