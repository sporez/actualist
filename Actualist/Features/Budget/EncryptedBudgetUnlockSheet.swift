import SwiftUI

struct EncryptedBudgetUnlockSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density

    @Binding var encryptionPassword: String

    let isUnlocking: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onUnlock: () -> Void

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Unlock Budget", subtitle: "Enter this budget's encryption password.")
            ReviewFormCard {
                ReviewFormFieldRow(title: "Encryption Password") {
                    SecureField("Encryption Password", text: $encryptionPassword)
                        .textInputAutocapitalization(.never)
                        .textContentType(.password)
                        .reviewSheetFieldStyle()
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(LocalFirstRecoveryGuidance.encryptionPasswordNotice)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton(action: onCancel)
            ReviewSheetPrimaryButton(action: onUnlock) {
                Text(isUnlocking ? "Unlocking" : "Unlock")
            }
            .disabled(encryptionPassword.isEmpty || isUnlocking)
        }
        .reviewSheetPresentation(detents: [.medium, .large], appState: appState)
        .interactiveDismissDisabled(isUnlocking)
    }
}
