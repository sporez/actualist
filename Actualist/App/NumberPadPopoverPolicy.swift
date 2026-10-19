import UIKit

/// iPadOS 26 shows number and decimal pads as a floating popover. A tap outside
/// it only closes the popover: the app gets no event, the field stays focused,
/// and the next tap anywhere is spent bringing the keyboard back instead of
/// reaching the control that was tapped. With the popover turned off, iPad uses
/// the docked keyboard's number layout, whose outside taps reach the app.
@MainActor
final class NumberPadPopoverPolicy: NSObject {
    private static let shared = NumberPadPopoverPolicy()
    private static var isInstalled = false

    static func install() {
        guard UIDevice.current.userInterfaceIdiom == .pad, !isInstalled else { return }
        isInstalled = true
        NotificationCenter.default.addObserver(
            shared,
            selector: #selector(editingDidBegin(_:)),
            name: UITextField.textDidBeginEditingNotification,
            object: nil
        )
    }

    @objc private func editingDidBegin(_ notification: Notification) {
        guard let field = notification.object as? UITextField,
              [.numberPad, .decimalPad].contains(field.keyboardType),
              field.allowsNumberPadPopover else { return }
        field.allowsNumberPadPopover = false
        // Editing has already begun, so the keyboard was chosen with the old trait.
        field.reloadInputViews()
    }
}
