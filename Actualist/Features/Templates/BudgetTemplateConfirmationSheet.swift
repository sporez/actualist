import SwiftUI

struct BudgetTemplateConfirmationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 6) {
                        Text("Review Template")
                            .font(.title2.weight(.bold))
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

                    if let display = viewModel.display {
                        BudgetTemplateReviewContent(display: display)
                    } else if viewModel.phase == .loading {
                        ProgressView("Loading preview")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    } else if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }

            VStack(spacing: 8) {
                Button(role: selectedConfirmation.buttonRole) {
                    guard let reviewRevision = viewModel.reviewRevision else { return }
                    apply(selectedConfirmation, reviewRevision)
                } label: {
                    Text(selectedConfirmation.actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .accessibilityIdentifier("template-apply-confirm")
                .buttonStyle(.glassProminent)
                .tint(selectedConfirmation.buttonTint)
                .disabled(!viewModel.canApply)

                Button(role: .cancel) {
                    cancel()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.small)
            .containerRelativeFrame(.horizontal) { width, _ in
                max(0, width - 44) * (dynamicTypeSize.isAccessibilitySize ? 1 : 0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(ActualistTheme.background)
        }
        .background(ActualistTheme.background)
        .task(id: "\(confirmation.id)|\(categoryID ?? "")|\(month)|\(String(describing: modeIdentity))|\(appState.settings.selectedBudgetID ?? "")|\(localDataRevision)|\(appState.settings.randomizedDisplayValuesEnabled)") {
            await load()
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

    private func load() async {
        await viewModel.loadIfNeeded(
            revision: localDataRevision,
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
