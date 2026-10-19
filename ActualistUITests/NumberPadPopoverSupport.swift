import XCTest

extension XCTestCase {
    @MainActor
    func dismissNumberPadPopover(in app: XCUIApplication, editor: XCUIElement) {
        let numberPad = app.popovers.containing(.key, identifier: "1").firstMatch
        guard numberPad.exists else { return }
        // iPadOS 26's number pad is modal. Tap its outside dismissal layer
        // before testing controls underneath; a docked keyboard needs no tap.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(numberPad.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editor.exists)
    }

    /// The editor focuses the amount when it opens. Wait for its keyboard or
    /// number pad, so a later tap is not swallowed by one still appearing.
    @MainActor
    func waitForAmountInput(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 3) { return }
        let floatingNumberPad = app.popovers.containing(.key, identifier: "1").firstMatch
        XCTAssertTrue(floatingNumberPad.waitForExistence(timeout: 5))
    }

    /// With a typed amount, Close asks before discarding it
    /// (see TransactionEditorUITests.testUnsavedInputBlocksSwipeAndAsksBeforeDiscarding).
    @MainActor
    func closeEditorDiscardingTypedAmount(_ editor: XCUIElement, in app: XCUIApplication) {
        dismissNumberPadPopover(in: app, editor: editor)
        let close = app.buttons["transaction-editor-close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.exists)
        discard.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    }
}
