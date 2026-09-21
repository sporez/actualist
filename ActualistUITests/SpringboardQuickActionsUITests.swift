import XCTest

@MainActor
final class SpringboardQuickActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppIconMenuListsFixedActionsAndRoutesColdAndWarmLaunches() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 15))
        app.terminate()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        let appIcon = springboard.icons["Actualist"]
        XCTAssertTrue(appIcon.waitForExistence(timeout: 5))
        appIcon.press(forDuration: 1.5)

        for title in ["Add Expense", "Budget", "Spending", "Accounts"] {
            XCTAssertTrue(springboard.buttons[title].waitForExistence(timeout: 3))
        }

        springboard.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 15))

        springboard.activate()
        appIcon.press(forDuration: 1.5)
        XCTAssertTrue(springboard.buttons["Spending"].waitForExistence(timeout: 3))
        springboard.buttons["Spending"].tap()
        XCTAssertTrue(
            app.tabBars.buttons["Spending"].waitForExistence(timeout: 15)
                && app.tabBars.buttons["Spending"].isSelected
        )
    }
}
