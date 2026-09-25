import XCTest

@MainActor
final class TransactionStatusFilterUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSpendingStatusStripKeepsFullOptionsAndSelectedTrait() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchSpending()
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertTrue(all.isSelected)
        XCTAssertTrue(app.otherElements["Transaction filters"].exists
                      || app.scrollViews["Transaction filters"].exists)

        app.buttons["Uncleared"].tap()
        XCTAssertTrue(app.buttons["Uncleared"].isSelected)
        XCTAssertFalse(all.isSelected)

        let strip = app.scrollViews["Transaction filters"]
        if strip.exists { strip.swipeLeft() }
        let reconciled = app.buttons["Reconciled"]
        XCTAssertTrue(reconciled.waitForExistence(timeout: 3))
        XCTAssertTrue(reconciled.isHittable)
        reconciled.tap()
        XCTAssertTrue(reconciled.isSelected)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(reconciled.waitForExistence(timeout: 3))
        XCTAssertTrue(reconciled.isHittable)

        attachScreenshot(named: "spending-status-filters-dark", app: app)
    }

    func testStatusLabelsRemainReachableAtAccessibilityTextSize() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = [
            "-actualist-demo", "-actualist-screen", "spending",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 15))
        let strip = app.scrollViews["Transaction filters"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        strip.swipeLeft()

        let reconciled = app.buttons["Reconciled"]
        XCTAssertEqual(reconciled.label, "Reconciled")
        XCTAssertTrue(reconciled.isHittable)
        reconciled.tap()
        XCTAssertTrue(reconciled.isSelected)
    }

    func testSearchKeyboardLeavesStatusChipsUsable() throws {
        let app = launchSpending()
        app.buttons["Search Transactions"].tap()
        let search = app.textFields["Search Transactions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("market")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        let strip = app.scrollViews["Transaction filters"]
        XCTAssertTrue(strip.exists)
        strip.swipeLeft()
        let reconciled = app.buttons["Reconciled"]
        XCTAssertTrue(reconciled.isHittable)
        reconciled.tap()
        XCTAssertTrue(reconciled.isSelected)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    func testAccountBalanceRemainsWhenStatusFilterChanges() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "accounts"]
        app.launch()
        let accounts = app.navigationBars["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 15))
        app.staticTexts["Everyday Checking"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))

        let summary = app.staticTexts["account-working-balance"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let balance = summary.label
        app.buttons["Cleared"].tap()
        XCTAssertTrue(app.buttons["Cleared"].isSelected)
        XCTAssertEqual(summary.label, balance)
        attachScreenshot(named: "account-status-filters-dark", app: app)
    }

    func testSpendingStatusFiltersInLightAppearance() throws {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        let theme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        theme.tap()
        let lightTheme = app.buttons["Actual Purple (light)"]
        XCTAssertTrue(lightTheme.waitForExistence(timeout: 3))
        lightTheme.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        app.terminate()

        let spending = launchSpending()
        XCTAssertTrue(spending.buttons["All"].waitForExistence(timeout: 10))
        XCTAssertTrue(spending.buttons["Reconciled"].exists)
        attachScreenshot(named: "spending-status-filters-light", app: spending)
    }

    func testFilterSurvivesEditorReturnAndResetsAfterTabExit() throws {
        let app = launchSpending()
        let cleared = app.buttons["Cleared"]
        cleared.tap()
        XCTAssertTrue(cleared.isSelected)

        app.buttons["Add Transaction"].tap()
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5))
        app.navigationBars["Add Transaction"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 5))
        XCTAssertTrue(cleared.isSelected)

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Spending"].tap()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["All"].isSelected)
        XCTAssertFalse(cleared.isSelected)
    }

    private func launchSpending() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "spending"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 15))
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
