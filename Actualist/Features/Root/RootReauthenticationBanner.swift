import SwiftUI

struct RootReauthenticationBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(ActualistTheme.warning)
            Text("Your Actual session expired. Sign in again to resume syncing.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
            Spacer(minLength: 8)
            Button("Sign In Again") { appState.beginReauthentication() }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ActualistTheme.background)
    }
}
