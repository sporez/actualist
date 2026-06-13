import SwiftUI

struct GlassPanel<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .glassEffect(
                .regular.tint(ActualistTheme.surface.opacity(0.42)),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
    }
}
