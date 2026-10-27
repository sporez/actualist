import SwiftUI

/// The shared-link wait banner and its failure alert. Presentation only: the
/// resolver owns the state and the copy.
struct SharedTransactionLinkStatus: ViewModifier {
    let resolver: SharedTransactionLinkResolver
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if resolver.state == .syncing {
                    banner
                }
            }
            .alert(
                resolver.failure?.title ?? "",
                isPresented: Binding(
                    get: { resolver.failure != nil },
                    set: { if !$0 { resolver.dismissFailure() } }
                ),
                presenting: resolver.failure
            ) { _ in
                Button("OK", role: .cancel) { resolver.dismissFailure() }
            } message: { failure in
                Text(failure.message)
            }
    }

    private var banner: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Finding transaction…")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .buttonStyle(.glass)
                .accessibilityIdentifier("shared-transaction-link-cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ActualistTheme.background)
        .accessibilityIdentifier("shared-transaction-link-finding")
    }
}
