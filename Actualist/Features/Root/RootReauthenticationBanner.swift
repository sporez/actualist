import SwiftUI

struct RootReauthenticationBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(ActualistTheme.warning)
            Text("You have been signed out of your Actual server. Sign in again to keep syncing.")
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
