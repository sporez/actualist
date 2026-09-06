import XCTest

final class AdaptiveSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCompactSettingsCategoriesOpenByTappingRows() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings"]
        app.launch()
        guard app.frame.width < 700 else { throw XCTSkip("Requires compact navigation") }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        for title in ["Connection & Sync", "Budget & Data", "Appearance"] {
            let row = app.cells.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            app.navigationBars[title].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "iphone-settings-tappable-categories"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testWideSettingsKeepsMenuWhileSwitchingDetail() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings"]
        app.launch()
        guard app.frame.width >= 1100 else { throw XCTSkip("Requires a wide iPad") }
        XCTAssertTrue(app.navigationBars["Connection & Sync"].waitForExistence(timeout: 15))
        let appearance = app.cells.containing(.staticText, identifier: "Appearance").firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        let budgetData = app.cells.containing(.staticText, identifier: "Budget & Data").firstMatch
        XCTAssertTrue(budgetData.isHittable)
        budgetData.tap()
        XCTAssertTrue(app.navigationBars["Budget & Data"].waitForExistence(timeout: 5))
        XCTAssertTrue(appearance.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ipad-settings-menu-detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let sidebarToggle = app.navigationBars["Actualist"].buttons.firstMatch
        XCTAssertTrue(sidebarToggle.isHittable)
        sidebarToggle.tap()
        XCTAssertTrue(appearance.isHittable)
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        let hiddenSidebar = XCTAttachment(screenshot: app.screenshot())
        hiddenSidebar.name = "ipad-settings-main-sidebar-hidden"
        hiddenSidebar.lifetime = .keepAlways
        add(hiddenSidebar)
    }

    @MainActor
    func testWideSettingsNestedRouteCanSwitchCategory() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/budget-data/payees"]
        app.launch()
        guard app.frame.width >= 1100 else { throw XCTSkip("Requires a wide iPad") }
        XCTAssertTrue(app.navigationBars["Payees"].waitForExistence(timeout: 15))
        app.cells.containing(.staticText, identifier: "Appearance").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Payees"].exists)
    }

    @MainActor
    func testWideBudgetHeaderRemainsVisibleAfterScrolling() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        app.launch()
        guard app.frame.width >= 1100 else { throw XCTSkip("Requires a wide iPad") }
        let grid = app.scrollViews["budget-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        grid.swipeUp()
        XCTAssertTrue(app.staticTexts["Category"].firstMatch.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ipad-budget-scrolled-header"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
