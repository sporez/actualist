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

    /// Reloads the preview whenever any input that shapes it changes.
    private struct LoadKey: Hashable {
        let confirmationID: String
        let categoryID: String?
        let month: String
        let modeIdentity: BudgetModeIdentity?
        let budgetID: String?
        let localDataRevision: UInt64
        let randomized: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(
            confirmationID: confirmation.id,
            categoryID: categoryID,
            month: month,
            modeIdentity: modeIdentity,
            budgetID: appState.settings.selectedBudgetID,
            localDataRevision: localDataRevision,
            randomized: appState.settings.randomizedDisplayValuesEnabled
        )
    }

    private var isMonthConfirmation: Bool {
        confirmation != .category
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ReviewSheetHeader(title: "Review Template", subtitle: selectedConfirmation.message)

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
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ReviewSheetActions {
                ReviewSheetSecondaryButton(action: cancel)

                ReviewSheetPrimaryButton(
                    role: selectedConfirmation.buttonRole,
                    tint: selectedConfirmation.buttonTint
                ) {
                    guard let reviewRevision = viewModel.reviewRevision else { return }
                    apply(selectedConfirmation, reviewRevision)
                } label: {
                    Text(selectedConfirmation.actionTitle)
                }
                .accessibilityIdentifier("template-apply-confirm")
                .disabled(!viewModel.canApply)
            }
        }
        .background(ActualistTheme.background)
        .task(id: loadKey) {
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
