import SwiftUI

struct TransactionBatchCategoryPickerView: View {
    @Environment(\.actualistDensity) private var density
    @Bindable var workflow: TransactionBatchCategoryPickerWorkflow
    let onSelect: (String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ReviewSheetContent {
                ReviewSheetHeader(
                    title: "Categorize Transactions",
                    subtitle: "Choose one category for the selected rows."
                )

                TextField("Search Categories", text: $workflow.searchText)
                    .font(ActualistTypography.body(for: density))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationBackground(ActualistTheme.background)
    }
}
