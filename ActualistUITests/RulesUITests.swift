import XCTest

@MainActor
final class RulesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Actual's rule editor does not offer Transfer or Parent Transaction as
    /// conditions; rule runs never fill them, so they could never match.
    func testNewConditionFieldMenuOmitsTransferAndParent() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "rules",
        ]
        app.launch()

        let create = app.buttons["Create Rule"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()

        let addCondition = app.buttons["Add Condition"]
        XCTAssertTrue(addCondition.waitForExistence(timeout: 10))
        let fieldMenu = app.buttons["Field"].firstMatch
        if !fieldMenu.waitForExistence(timeout: 2) {
            addCondition.tap()
        }
        XCTAssertTrue(fieldMenu.waitForExistence(timeout: 5))
        fieldMenu.tap()

        XCTAssertTrue(app.buttons["Payee"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Account"].exists)
        XCTAssertFalse(app.buttons["Transfer"].exists)
        XCTAssertFalse(app.buttons["Parent Transaction"].exists)
    }
}
