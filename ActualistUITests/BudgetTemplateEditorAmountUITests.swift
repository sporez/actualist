import XCTest

@MainActor
final class BudgetTemplateEditorAmountUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// A Fixed Amount template's Amount field keeps what was typed after Save and a reopen.
    func testTypedFixedAmountSurvivesSaveAndReopen() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "templates",
        ]
        app.launch()

        openUtilitiesTemplate(in: app)
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        amount.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let existing = (amount.value as? String) ?? ""
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        amount.typeText("123.45")

        let save = app.buttons["Save"]
        if !save.isHittable { app.staticTexts["This month"].tap() }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))

        openUtilitiesTemplate(in: app)
        let reopened = app.textFields["Amount"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertEqual(reopened.value as? String, "123.45")
    }

    private func openUtilitiesTemplate(in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Utilities'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
    }
}
