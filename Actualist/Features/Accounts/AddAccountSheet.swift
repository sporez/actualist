import SwiftUI

struct AddAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: AddAccountViewModel

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Add Account")
            ReviewFormCard {
                ReviewFormFieldRow(title: "Name") {
                    TextField("Checking", text: $viewModel.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit {
                            Task { await submit() }
                        }
                        .reviewSheetFieldStyle()
                }
            }
            ReviewFormCard {
                ReviewFormFieldRow(title: "Type") {
                    Picker("Account Type", selection: $viewModel.kind) {
                        ForEach(AddAccountViewModel.AccountKind.allCases) { kind in
                            Text(kind.title)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Text(viewModel.kind.detail)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton {
                viewModel.reset()
                dismiss()
            }
            .disabled(viewModel.isSubmitting)
            ReviewSheetPrimaryButton {
                Task { await submit() }
            } label: {
                if viewModel.isSubmitting {
                    ProgressView()
                } else {
                    Text("Create Account")
                }
            }
            .disabled(!viewModel.canSubmit)
        }
        .reviewSheetPresentation(detents: [.medium, .large], appState: appState)
        .onDisappear {
            if !viewModel.isSubmitting {
                viewModel.reset()
            }
        }
    }

    private func submit() async {
        guard await viewModel.submit(
            budgetID: appState.settings.selectedBudgetID,
            repository: appState.accountRepository
        ) else {
            return
        }

        ActualistHaptics.success()
        dismiss()
    }
}
