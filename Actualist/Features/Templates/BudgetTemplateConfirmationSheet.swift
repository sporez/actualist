import SwiftUI

struct BudgetTemplateConfirmationSheet: View {
    @Environment(AppState.self) private var appState
    let confirmation: BudgetTemplateConfirmation
    let categoryID: String?
    let month: String
    let modeIdentity: BudgetModeIdentity?
    let localDataRevision: UInt64
    let cancel: () -> Void
    let apply: (BudgetTemplateConfirmation, BudgetTemplateReviewRevision) -> Void

    @State private var viewModel = BudgetTemplateApplyPreviewViewModel()

    private var isMonthConfirmation: Bool {
        confirmation != .category
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 8) {
                        Text("Review template")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)

                        Text(selectedConfirmation.message)
                            .font(.subheadline)
                            .foregroundStyle(ActualistTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isMonthConfirmation {
                        modePicker
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
                Button(role: selectedConfirmation.buttonRole) {
                    guard let reviewRevision = viewModel.reviewRevision else { return }
                    apply(selectedConfirmation, reviewRevision)
                } label: {
                    Text(selectedConfirmation.actionTitle)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .accessibilityIdentifier("template-apply-confirm")
                .buttonStyle(.glassProminent)
                .tint(selectedConfirmation.buttonTint)
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
        .task(id: "\(confirmation.id)|\(categoryID ?? "")|\(month)|\(String(describing: modeIdentity))|\(appState.settings.selectedBudgetID ?? "")|\(localDataRevision)|\(appState.settings.randomizedDisplayValuesEnabled)") {
            await load()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private var selectedConfirmation: BudgetTemplateConfirmation {
        viewModel.selectedConfirmation ?? confirmation
    }

    @ViewBuilder
    private var modePicker: some View {
        Picker("Apply mode", selection: Binding(
            get: { viewModel.selectedMode ?? initialMode },
            set: { viewModel.selectMode($0) }
        )) {
            Text("Fill Empty").tag(BudgetTemplateApplyPreviewViewModel.Mode.fillEmpty)
            Text("Overwrite").tag(BudgetTemplateApplyPreviewViewModel.Mode.overwrite)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("template-apply-mode")
    }

    private var initialMode: BudgetTemplateApplyPreviewViewModel.Mode {
        confirmation == .monthOverwrite ? .overwrite : .fillEmpty
    }

    @ViewBuilder
    private func previewContent(_ display: BudgetTemplateApplyPreviewDisplay) -> some View {
        VStack(spacing: 10) {
            totalRow("Funding required", display.fundingRequiredText)
            totalRow("Will assign", display.assignedText)
            if let releasedText = display.releasedText {
                totalRow(display.releasedTitle, releasedText)
            }
            if let stillNeededText = display.stillNeededText {
                totalRow("Still needed", stillNeededText, valueColor: ActualistTheme.warning)
            }
            totalRow(
                display.leftoverTitle,
                "\(display.leftoverBeforeText) → \(display.leftoverAfterText)"
            )
            totalRow("Categories", display.changeCountText)
        }
        .accessibilityElement(children: .contain)

        if let warningText = display.warningText {
            Text(warningText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ActualistTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }

        if display.hasNonMoneyUpdates {
            Text("Goal targets will also be updated.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let noOpExplanation = display.noOpExplanation {
            Text(noOpExplanation)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !display.categories.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(display.categories) { category in
                    categoryRow(category)
                }
            }
        }
    }

    private func categoryRow(_ category: BudgetTemplateApplyPreviewDisplay.Category) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(category.name)
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(category.currentText) → \(category.proposedText)")
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.subheadline)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(category.metricTitle)
                Spacer(minLength: 8)
                Text("\(category.metricBeforeText) → \(category.metricAfterText)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.caption)
            .foregroundStyle(ActualistTheme.secondaryText)

            Text(category.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(category.shortfallText == nil ? ActualistTheme.positive : ActualistTheme.warning)

            if let shortfallText = category.shortfallText {
                Text("Shortfall \(shortfallText)")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.warning)
            }
            if let targetDetailText = category.targetDetailText {
                Text(targetDetailText)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("template-preview-category-\(category.id)")
    }

    private func totalRow(_ title: String, _ value: String, valueColor: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor ?? ActualistTheme.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }

    private func load() async {
        await viewModel.load(
            confirmation: confirmation,
            categoryID: categoryID,
            month: month,
            budgetID: appState.settings.selectedBudgetID,
            modeIdentity: modeIdentity,
            randomized: appState.settings.randomizedDisplayValuesEnabled,
            repository: appState.budgetRepository
        )
    }
}
