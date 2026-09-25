import SwiftUI

struct CredentialRecoveryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(ActualistTheme.warning)
            Text("Saved credentials unavailable")
                .font(.title3.bold())
            Text(appState.credentialRecoveryMessage ?? "This device could not read its saved credentials.")
                .multilineTextAlignment(.center)
                .foregroundStyle(ActualistTheme.secondaryText)
            Button("Try Again") {
                Task { await appState.retryCredentialAccess() }
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .accessibilityIdentifier("credentialRecoveryRetry")
        }
        .frame(maxWidth: 600)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
