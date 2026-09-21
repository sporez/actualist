import SwiftUI

struct BudgetCategoryDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: BudgetCategoryLifecycleController
    let selectedMonth: String?
    let budgetID: String?
    let repository: any BudgetRepositoryProtocol
    let onDeleted: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let target = controller.deletion.target {
                    Section {
                        Text(target.reviewMessage)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section("Transfer To") {
                        Picker("Category", selection: destinationBinding) {
                            Text("Choose a category").tag(String?.none)
                            ForEach(controller.deletion.destinations) { destination in
                                Text(destinationLabel(destination)).tag(Optional(destination.id))
                            }
                        }
                        .accessibilityIdentifier("budget-category-delete-destination")
                    }
                }

                if let errorMessage = controller.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(ActualistTheme.danger)
                            .accessibilityIdentifier("budget-category-delete-error")
                    }
                }
            }
            .accessibilityIdentifier("budget-category-delete-sheet")
            .navigationTitle(controller.deletion.target?.deleteTitle ?? "Delete")
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
                    Button("Delete", role: .destructive) { delete() }
                        .disabled(controller.deletion.selectedDestinationID == nil || controller.isSubmitting)
                        .accessibilityIdentifier("budget-category-delete-confirm")
                }
            }
        }
        .interactiveDismissDisabled(controller.isSubmitting)
    }

    private var destinationBinding: Binding<String?> {
        Binding(
            get: { controller.deletion.selectedDestinationID },
            set: { controller.deletion.selectDestination($0) }
        )
    }

    private func destinationLabel(_ destination: BudgetCategoryDeletionWorkflow.Destination) -> String {
        let label = "\(destination.groupName) · \(destination.name)"
        return destination.hidden ? "\(label) (Hidden)" : label
    }

    private func delete() {
        Task {
            guard await controller.confirmDeletion(
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) else { return }
            await onDeleted()
            dismiss()
        }
    }
}
