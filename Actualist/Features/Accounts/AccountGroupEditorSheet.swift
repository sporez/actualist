import SwiftUI

struct AccountGroupEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var name: String
    let errorMessage: String?
    let isSubmitting: Bool
    let canSubmit: Bool
    let onCancel: () -> Void
    let onSubmit: () async -> Bool

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: title)
            ReviewFormCard {
                ReviewFormFieldRow(title: "Name") {
                    TextField("Cash", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit {
                            Task { await submit() }
                        }
                        .reviewSheetFieldStyle()
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton {
                onCancel()
                dismiss()
            }
            ReviewSheetPrimaryButton {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView()
                } else {
                    Text("Save")
                }
            }
            .disabled(!canSubmit)
        }
        .reviewSheetPresentation(detents: [.medium, .large], appState: appState)
    }

    private func submit() async {
        guard await onSubmit() else {
            return
        }
        dismiss()
    }
}
