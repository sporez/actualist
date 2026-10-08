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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ReviewSheetHeader(title: controller.deletion.target?.deleteTitle ?? "Delete")

                if let target = controller.deletion.target {
                    ReviewFormCard {
                        ReviewFormFieldRow(title: "Transfer Required") {
                            Text(target.reviewMessage)
                                .font(ActualistTypography.body(for: density))
                                .foregroundStyle(ActualistTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ReviewFormCard {
                        ReviewFormFieldRow(title: "Transfer To") {
                            Picker("Category", selection: destinationBinding) {
                                Text("Choose a category").tag(String?.none)
                                ForEach(controller.deletion.destinations) { destination in
                                    Text(destinationLabel(destination)).tag(Optional(destination.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .tint(ActualistTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("budget-category-delete-destination")
                        }
                    }
                }

                if let errorMessage = controller.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("budget-category-delete-error")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .accessibilityIdentifier("budget-category-delete-sheet")
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton {
                controller.cancel()
                dismiss()
            }
            .disabled(controller.isSubmitting)

            ReviewSheetPrimaryButton(role: .destructive, tint: ActualistTheme.danger) {
                delete()
            } label: {
                if controller.isSubmitting {
                    ProgressView()
                } else {
                    Text("Delete")
                }
            }
            .disabled(controller.deletion.selectedDestinationID == nil || controller.isSubmitting)
            .accessibilityIdentifier("budget-category-delete-confirm")
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
