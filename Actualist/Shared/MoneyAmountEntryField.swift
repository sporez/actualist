import SwiftUI

enum MoneyAmountEntryKeyboard {
    case digits
    case signedDecimal
}

/// Shared large-amount entry used by money workflows that keep parsing and
/// command values in their feature-owned models.
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
                .accessibilityHidden(true)

            TextField(accessibilityLabel, text: $text)
                .focused(focus)
                .keyboardType(keyboard == .digits ? .numberPad : .numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(displayText)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            focus.wrappedValue = true
        }
    }
}
