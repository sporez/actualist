import SwiftUI

enum ActualistTheme {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.05)
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.15)
    static let elevatedSurface = Color(red: 0.10, green: 0.10, blue: 0.19)
    static let control = Color(red: 0.17, green: 0.17, blue: 0.24)
    static let accent = Color(red: 0.49, green: 0.52, blue: 1.00)
    static let positive = Color(red: 0.55, green: 0.78, blue: 0.24)
    static let warning = Color(red: 0.95, green: 0.78, blue: 0.28)
    static let danger = Color(red: 0.90, green: 0.29, blue: 0.33)
    static let primaryText = Color(red: 0.96, green: 0.96, blue: 0.99)
    static let secondaryText = Color(red: 0.72, green: 0.73, blue: 0.78)
    static let separator = Color.white.opacity(0.10)
}

extension View {
    func actualistScreenBackground() -> some View {
        background(ActualistTheme.background.ignoresSafeArea())
    }

    func glassControlCapsule() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular.tint(ActualistTheme.control.opacity(0.34)), in: Capsule())
    }

    func actualistToolbarGlassButton() -> some View {
        self
            .font(.body.weight(.semibold))
            .controlSize(.small)
    }
}
