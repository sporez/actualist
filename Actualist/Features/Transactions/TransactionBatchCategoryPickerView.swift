import SwiftUI

struct TransactionBatchCategoryPickerView: View {
    @Environment(\.actualistDensity) private var density
    @Bindable var workflow: TransactionBatchCategoryPickerWorkflow
    let onSelect: (String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(
                title: "Categorize Transactions",
                subtitle: "Choose one category for the selected rows."
            )

            TextField("Search Categories", text: $workflow.searchText)
                .reviewSheetFieldStyle()
                .accessibilityIdentifier("transaction-batch-category-search")

            Button("Uncategorized", systemImage: "tag.slash") { onSelect(nil) }
                .buttonStyle(.plain)
                .actualistReviewCard(padding: 12)
                .accessibilityIdentifier("transaction-batch-category-uncategorized")

            if workflow.isLoading && workflow.groups.isEmpty {
                ProgressView("Loading categories")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage = workflow.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                    Button("Try Again") { Task { await workflow.load() } }
                        .buttonStyle(.glass)
                }
                .actualistReviewCard()
            } else if workflow.visibleGroups.isEmpty {
                Text(workflow.searchText.isEmpty ? "No categories available" : "No matching categories")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .actualistReviewCard(padding: 12)
            } else {
                ForEach(workflow.visibleGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.name)
                            .font(ActualistTypography.rowLabel(for: density).weight(.bold))
                            .foregroundStyle(ActualistTheme.secondaryText)

                        ForEach(group.options) { option in
                            Button {
                                onSelect(option.id)
                            } label: {
                                HStack {
                                    Text(option.title)
                                        .foregroundStyle(ActualistTheme.primaryText)
                                    Spacer(minLength: 8)
                                    if let valueText = option.valueText {
                                        Text(valueText)
                                            .font(ActualistTypography.rowBadge(for: density))
                                            .foregroundStyle(ActualistTheme.secondaryText)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("transaction-batch-category-\(option.id)")
                        }
                    }
                    .actualistReviewCard(padding: 12)
                }
            }
        }
        .reviewSheetBottomBar {
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("batch-category-picker-cancel")
            Spacer(minLength: 0)
        }
        .background(ActualistTheme.background)
        .presentationBackground(ActualistTheme.background)
    }
}
