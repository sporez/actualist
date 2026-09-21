import XCTest

@MainActor
final class TransactionEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAmountFormatsMinorUnitsAndScrollDismissesKeyboard() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()

        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 10))
        addTransaction.tap()
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5))

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.typeText("1")
        XCTAssertTrue(formattedAmount(containing: "0.01", in: app).waitForExistence(timeout: 5))

        app.typeText("2")
        XCTAssertTrue(formattedAmount(containing: "0.12", in: app).waitForExistence(timeout: 5))

        let split = app.buttons["Split"]
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.tap()
        XCTAssertTrue(keyboard.exists)

        let editorScroll = app.scrollViews["transaction-editor-scroll"]
        XCTAssertTrue(editorScroll.waitForExistence(timeout: 5))
        let payee = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Payee'")).firstMatch
        let payeeY = payee.frame.minY
        editorScroll.swipeDown()
        XCTAssertGreaterThan(payee.frame.minY, payeeY + 20, "Editor did not scroll from \(payeeY) to \(payee.frame.minY)")
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Keyboard remained at \(keyboard.frame)")
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func formattedAmount(containing amount: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", amount)).firstMatch
    }
}
