import XCTest

@MainActor
final class SpringboardQuickActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppIconMenuListsFixedActionsAndRoutesColdAndWarmLaunches() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        app.launch()
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        let compact = app.usesCompactLayout
        app.terminate()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        // iPad Springboard lists the icon more than once (home page and dock).
        let appIcon = springboard.icons.matching(identifier: try UITestAppIdentity.appDisplayName).firstMatch
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
        if compact {
            XCTAssertTrue(
                app.tabBars.buttons["Spending"].waitForExistence(timeout: 15)
                    && app.tabBars.buttons["Spending"].isSelected
            )
        } else {
            XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 15))
        }
    }
}
