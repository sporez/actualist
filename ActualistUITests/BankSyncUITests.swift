import XCTest

@MainActor
final class BankSyncUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBankSyncIsAvailableWithoutExperimentalSettings() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        for (theme, suffix) in [("Actual Purple (light)", "light"), ("Actual Purple (dark)", "dark")] {
            app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
            picker.tap()
            app.buttons[theme].tap()
            app.terminate()

            app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/budget-data/bank-sync"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Bank Sync"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Provider, Unavailable in demo mode"].waitForExistence(timeout: 5))
            let background = app.switches["Background Bank Sync"]
            XCTAssertTrue(background.exists)
            XCTAssertFalse(background.isEnabled)
            XCTAssertFalse(app.buttons["Sync All"].isEnabled)
            XCTAssertFalse(app.navigationBars["Review Bank Sync"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "bank-sync-\(suffix)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()

            app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/advanced"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts["Experimental Features"].exists)
            XCTAssertFalse(app.switches["Background Bank Sync"].exists)
            let advanced = XCTAttachment(screenshot: app.screenshot())
            advanced.name = "advanced-\(suffix)"
            advanced.lifetime = .keepAlways
            add(advanced)
            app.terminate()
        }
    }
}
