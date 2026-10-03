import XCTest

@MainActor
final class AdaptiveSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCompactSettingsCategoriesOpenByTappingRows() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
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
    func testDemoSupportCanShareReportDismissAndReopen() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        let themePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(themePicker.waitForExistence(timeout: 5))
        themePicker.tap()
        let darkTheme = app.buttons["Actual Purple (dark)"]
        XCTAssertTrue(darkTheme.waitForExistence(timeout: 5))
        darkTheme.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        app.navigationBars["Appearance"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let supportRow = app.cells.containing(.staticText, identifier: "Support").firstMatch
        XCTAssertTrue(supportRow.waitForExistence(timeout: 5))
        supportRow.tap()
        XCTAssertTrue(app.navigationBars["Support"].waitForExistence(timeout: 15))
        let shareButton = app.buttons["diagnostic-report-share"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10))

        let supportScreenshot = XCTAttachment(screenshot: app.screenshot())
        supportScreenshot.name = "support-diagnostic-report"
        supportScreenshot.lifetime = .keepAlways
        add(supportScreenshot)

        shareButton.tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10))

        let shareScreenshot = XCTAttachment(screenshot: app.screenshot())
        shareScreenshot.name = "support-diagnostic-report-share-sheet"
        shareScreenshot.lifetime = .keepAlways
        add(shareScreenshot)

        dismissShareSheet(in: app, sheet: shareSheet)
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))

        shareButton.tap()
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10))
        dismissShareSheet(in: app, sheet: shareSheet)
    }

    @MainActor
    func testDemoSupportShareWithAlwaysPrivacyInLightTheme() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        let themePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(themePicker.waitForExistence(timeout: 5))
        themePicker.tap()
        let lightTheme = app.buttons["Actual Purple (light)"]
        XCTAssertTrue(lightTheme.waitForExistence(timeout: 5))
        lightTheme.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))

        app.navigationBars["Appearance"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let privacyRow = app.cells.containing(.staticText, identifier: "Privacy & Notifications").firstMatch
        XCTAssertTrue(privacyRow.waitForExistence(timeout: 5))
        privacyRow.tap()
        XCTAssertTrue(app.navigationBars["Privacy & Notifications"].waitForExistence(timeout: 5))

        let appSwitcherPicker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'App Switcher'")
        ).firstMatch
        XCTAssertTrue(appSwitcherPicker.waitForExistence(timeout: 5))
        appSwitcherPicker.tap()
        let alwaysPrivacy = app.buttons["Always"]
        XCTAssertTrue(alwaysPrivacy.waitForExistence(timeout: 5))
        alwaysPrivacy.tap()

        app.navigationBars["Privacy & Notifications"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let supportRow = app.cells.containing(.staticText, identifier: "Support").firstMatch
        XCTAssertTrue(supportRow.waitForExistence(timeout: 5))
        supportRow.tap()
        XCTAssertTrue(app.navigationBars["Support"].waitForExistence(timeout: 5))

        let shareButton = app.buttons["diagnostic-report-share"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10))
        let supportScreenshot = XCTAttachment(screenshot: app.screenshot())
        supportScreenshot.name = "support-diagnostic-report-light-always-privacy"
        supportScreenshot.lifetime = .keepAlways
        add(supportScreenshot)

        shareButton.tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10))
        let shareScreenshot = XCTAttachment(screenshot: app.screenshot())
        shareScreenshot.name = "support-diagnostic-report-share-sheet-light-always-privacy"
        shareScreenshot.lifetime = .keepAlways
        add(shareScreenshot)

        dismissShareSheet(in: app, sheet: shareSheet)
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        shareButton.tap()
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10))
        dismissShareSheet(in: app, sheet: shareSheet)
    }

    private func dismissShareSheet(in app: XCUIApplication, sheet: XCUIElement) {
        // iOS 27 exposes native sharing as a popover with a dismiss region;
        // its embedded ActivityListView cannot receive a swipe through XCTest.
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if dismissRegion.exists {
            dismissRegion.tap()
        } else {
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
        }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testWideDemoReentryLeavesSidebarSettings() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/connection"]
        app.launch()
        guard app.frame.width >= 1100 else { throw XCTSkip("Requires a wide iPad") }
        XCTAssertTrue(app.navigationBars["Connection & Sync"].waitForExistence(timeout: 15))
        app.buttons["Exit Demo Mode"].tap()
        XCTAssertTrue(app.staticTexts["Exit Demo Mode?"].waitForExistence(timeout: 5))
        let confirm = try XCTUnwrap(
            app.buttons.matching(identifier: "Exit Demo Mode").allElementsBoundByIndex.first { $0.isHittable }
        )
        confirm.tap()
        let demo = app.buttons["Demo"].firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        XCTAssertTrue(app.buttons["Enter Demo"].waitForExistence(timeout: 5))
        app.buttons["Enter Demo"].tap()
        // The fresh demo session must land on the Budget workspace, not restore
        // the Settings destination left selected by the session that was erased.
        XCTAssertTrue(app.scrollViews["budget-grid"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.navigationBars["Connection & Sync"].exists)
    }

    @MainActor
    func testWideSettingsKeepsMenuWhileSwitchingDetail() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
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
        let app = XCUIApplication()
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
        let app = XCUIApplication()
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
