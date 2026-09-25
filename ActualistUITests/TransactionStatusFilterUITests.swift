import XCTest

@MainActor
final class TransactionStatusFilterUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSpendingFilterMenuAndClearIndicator() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchSpending()
        let filterMenu = app.buttons["Filter Transactions"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 10))
        filterMenu.tap()
        assertAllFilterChoices(in: app)
        app.buttons["Uncleared"].tap()

        let indicator = app.buttons["Clear Uncleared Filter"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertTrue(indicator.label.contains("Uncleared"))
        attachScreenshot(named: "spending-status-filter-dark", app: app)

        indicator.tap()
        XCTAssertFalse(indicator.waitForExistence(timeout: 2))
        XCTAssertTrue(filterMenu.exists)
    }

    func testFilterMenuRemainsReachableAtAccessibilityTextSize() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = [
            "-actualist-demo", "-actualist-screen", "spending",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 15))
        let filterMenu = app.buttons["Filter Transactions"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(filterMenu.isHittable)
        filterMenu.tap()
        assertAllFilterChoices(in: app)
        app.buttons["Reconciled"].tap()
        XCTAssertTrue(app.buttons["Clear Reconciled Filter"].waitForExistence(timeout: 5))
    }

    func testSearchKeyboardLeavesFilterMenuUsable() throws {
        let app = launchSpending()
        app.buttons["Search Transactions"].tap()
        let search = app.textFields["Search Transactions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("market")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        let filterMenu = app.buttons["Filter Transactions"]
        XCTAssertTrue(filterMenu.isHittable)
        filterMenu.tap()
        app.buttons["Reconciled"].tap()
        XCTAssertTrue(app.buttons["Clear Reconciled Filter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    func testAccountFilterMenuPreservesBalanceAndToolbarActions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "accounts"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 15))
        app.staticTexts["Everyday Checking"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))

        let summary = app.staticTexts["account-working-balance"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let balance = summary.label
        XCTAssertTrue(app.buttons["Account Actions"].exists)
        XCTAssertTrue(app.buttons["Search Transactions"].exists)
        XCTAssertTrue(app.buttons["Add Transaction"].exists)

        app.buttons["Account Actions"].tap()
        app.buttons["Filter Transactions"].tap()
        XCTAssertTrue(app.buttons["All"].isSelected)
        app.buttons["Cleared"].tap()
        let indicator = app.buttons["Clear Cleared Filter"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertTrue(indicator.isHittable)
        XCTAssertEqual(summary.label, balance)
        attachScreenshot(named: "account-status-filter-dark", app: app)

        // On iPad the List gives this button the full row's accessibility frame;
        // the balance marks the center of the visible detail pane, not the sidebar.
        app.coordinate(withNormalizedOffset: CGVector(
            dx: summary.frame.midX / app.frame.width,
            dy: indicator.frame.midY / app.frame.height
        )).tap()
        XCTAssertFalse(indicator.waitForExistence(timeout: 5))

        app.buttons["Account Actions"].tap()
        app.buttons["Filter Transactions"].tap()
        XCTAssertTrue(app.buttons["All"].isSelected)
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
        XCTAssertTrue(spending.buttons["Filter Transactions"].waitForExistence(timeout: 10))
        spending.buttons["Filter Transactions"].tap()
        spending.buttons["Reconciled"].tap()
        XCTAssertTrue(spending.buttons["Clear Reconciled Filter"].waitForExistence(timeout: 5))
        attachScreenshot(named: "spending-status-filter-light", app: spending)
    }

    func testFilterSurvivesEditorReturnAndResetsAfterTabExit() throws {
        let app = launchSpending()
        selectSpendingFilter("Cleared", in: app)
        let indicator = app.buttons["Clear Cleared Filter"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))

        app.buttons["Add Transaction"].tap()
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5))
        app.navigationBars["Add Transaction"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 5))
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Spending"].tap()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 5))
        XCTAssertFalse(indicator.exists)
        XCTAssertTrue(app.buttons["Filter Transactions"].exists)
    }

    private func launchSpending() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "spending"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 15))
        return app
    }

    private func selectSpendingFilter(_ filter: String, in app: XCUIApplication) {
        app.buttons["Filter Transactions"].tap()
        app.buttons[filter].tap()
    }

    private func assertAllFilterChoices(in app: XCUIApplication) {
        for filter in ["All", "Uncategorized", "Uncleared", "Cleared", "Reconciled"] {
            XCTAssertTrue(app.buttons[filter].exists, "Missing \(filter) filter choice")
        }
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
