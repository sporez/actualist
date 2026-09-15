import SwiftUI
import UIKit

enum MoneyAmountEntryKeyboard {
    case digits
    case decimal
}

/// Shared large-amount entry used by money workflows that keep parsing and
/// command values in their feature-owned models.
///
/// The overlay shows formatted text while idle. While focused, the TextField
/// itself is the visible amount so typing is not inserted into a hidden 1pt
/// caret at the start of the existing value.
struct MoneyAmountEntryField: View {
    @Environment(\.actualistDensity) private var density

    @Binding var text: String
    let displayText: String
    let foreground: Color
    let keyboard: MoneyAmountEntryKeyboard
    let focus: FocusState<Bool>.Binding
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    var body: some View {
        ZStack {
            Text(displayText)
                .font(ActualistTypography.editorAmount(for: density))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .opacity(focus.wrappedValue ? 0 : 1)
                .accessibilityHidden(true)

            TextField(accessibilityLabel, text: $text)
                .focused(focus)
                .font(ActualistTypography.editorAmount(for: density))
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .keyboardType(keyboard == .digits ? .numberPad : .decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .opacity(focus.wrappedValue ? 1 : 0.01)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(displayText)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            focus.wrappedValue = true
        }
        .onChange(of: focus.wrappedValue) { _, focused in
            guard focused else { return }
            Task { @MainActor in
                UIApplication.shared.sendAction(
                    #selector(UIResponder.selectAll(_:)),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
        }
    }
}
