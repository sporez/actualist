import SwiftUI

struct BudgetCategoryDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Bindable var controller: BudgetCategoryLifecycleController
    let selectedMonth: String?
    let budgetID: String?
    let repository: any BudgetRepositoryProtocol
    let onDeleted: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let target = controller.deletion.target {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Transfer Required")
                                .font(ActualistTypography.rowLabel(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)

                            Text(target.reviewMessage)
                                .font(ActualistTypography.body(for: density))
                                .foregroundStyle(ActualistTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            ActualistTheme.surface,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                        )

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Transfer To")
                                .font(ActualistTypography.rowLabel(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)

                            Picker("Category", selection: destinationBinding) {
                                Text("Choose a category").tag(String?.none)
                                ForEach(controller.deletion.destinations) { destination in
                                    Text(destinationLabel(destination)).tag(Optional(destination.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(ActualistTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("budget-category-delete-destination")
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            ActualistTheme.surface,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                        )
                    }

                    if let errorMessage = controller.errorMessage {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                            .accessibilityIdentifier("budget-category-delete-error")
                    }

                    Button(role: .destructive) { delete() } label: {
                        if controller.isSubmitting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Delete")
                                .font(ActualistTypography.control(for: density))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.danger)
                    .disabled(controller.deletion.selectedDestinationID == nil || controller.isSubmitting)
                    .accessibilityIdentifier("budget-category-delete-confirm")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
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
