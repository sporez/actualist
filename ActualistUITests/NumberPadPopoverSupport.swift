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
}
