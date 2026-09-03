import SwiftUI

struct BudgetTemplateConfirmationSheet: View {
    @Environment(AppState.self) private var appState
    let confirmation: BudgetTemplateConfirmation
    let categoryID: String?
    let month: String
    let cancel: () -> Void
    let apply: () -> Void

    @State private var viewModel = BudgetTemplateApplyPreviewViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 8) {
                        Text("Are you sure?")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)

                        Text(confirmation.message)
                            .font(.subheadline)
                            .foregroundStyle(ActualistTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if viewModel.phase == .loading {
                        ProgressView("Loading preview")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    } else if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let display = viewModel.display {
                        previewContent(display)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }

            VStack(spacing: 10) {
                Button(role: confirmation.buttonRole) {
                    apply()
                } label: {
                    Text(confirmation.actionTitle)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(confirmation.buttonTint)
                .disabled(!viewModel.canApply)

                Button(role: .cancel) {
                    cancel()
                } label: {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .background(ActualistTheme.background)
        }
        .background(ActualistTheme.background)
        .task(id: "\(confirmation.id)|\(categoryID ?? "")|\(month)") {
            await load()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    @ViewBuilder
    private func previewContent(_ display: BudgetTemplateApplyPreviewDisplay) -> some View {
        VStack(spacing: 10) {
            totalRow("Assigned", display.assignedText)
            totalRow(display.leftoverTitle, display.leftoverText)
            totalRow("Categories", display.changeCountText)
        }

        if !display.categories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(display.categories) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(category.name)
                                .foregroundStyle(ActualistTheme.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(category.currentText)
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ActualistTheme.secondaryText)
                            Text(category.proposedText)
                                .foregroundStyle(ActualistTheme.primaryText)
                                .lineLimit(1)
                        }
                        .font(.subheadline)

                        if !category.contributions.isEmpty {
                            ForEach(category.contributions) { contribution in
                                HStack {
                                    Text(contribution.title)
                                    Spacer(minLength: 8)
                                    Text(contribution.amountText)
                                }
                                .font(.caption)
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private func totalRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(ActualistTheme.primaryText)
        }
        .font(.subheadline)
    }

    private func load() async {
        await viewModel.load(
            confirmation: confirmation,
            categoryID: categoryID,
            month: month,
            budgetID: appState.settings.selectedBudgetID,
            randomized: appState.settings.randomizedDisplayValuesEnabled,
            repository: appState.budgetRepository
        )
    }
}
