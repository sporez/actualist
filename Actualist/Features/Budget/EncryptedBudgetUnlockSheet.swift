import SwiftUI

struct EncryptedBudgetUnlockSheet: View {
    @Environment(\.actualistDensity) private var density
    @State private var selectedDetent: PresentationDetent = .medium

    @Binding var encryptionPassword: String

    let isUnlocking: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onUnlock: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Encryption Password", text: $encryptionPassword)
                        .textInputAutocapitalization(.never)
                        .textContentType(.password)
                } footer: {
                    Text(LocalFirstRecoveryGuidance.encryptionPasswordNotice)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Unlock Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isUnlocking ? "Unlocking" : "Unlock", action: onUnlock)
                        .disabled(encryptionPassword.isEmpty || isUnlocking)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .appSwitcherPrivacyAwareDragIndicator()
        .interactiveDismissDisabled(isUnlocking)
        .appSwitcherPrivacyProtected()
    }
}
