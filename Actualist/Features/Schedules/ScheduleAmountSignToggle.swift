import SwiftUI

/// A narrow +/− switch that sits in front of the schedule amount field.
/// Tapping it flips between Deposit (+) and Spend (−).
struct ScheduleAmountSignToggle: View {
    let sign: ScheduleEditorAmountSign
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 2) {
                symbol("plus", isActive: sign == .deposit, fill: ActualistTheme.positive, foreground: ActualistTheme.positiveForeground)
                symbol("minus", isActive: sign == .spend, fill: ActualistTheme.danger, foreground: ActualistTheme.dangerForeground)
            }
            .padding(.vertical, 4)
            .frame(width: 30)
            .background(ActualistTheme.elevatedSurface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Amount direction")
        .accessibilityValue(sign.rawValue)
        .accessibilityHint("Switches between Spend and Deposit")
    }

    private func symbol(_ name: String, isActive: Bool, fill: Color, foreground: Color) -> some View {
        Image(systemName: name)
            .font(.caption.weight(.bold))
            .foregroundStyle(isActive ? foreground : ActualistTheme.secondaryText.opacity(0.6))
            .frame(width: 22, height: 20)
            .background(isActive ? fill : .clear, in: Circle())
    }
}
