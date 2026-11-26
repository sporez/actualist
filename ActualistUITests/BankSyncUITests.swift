import XCTest

@MainActor
final class BankSyncUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBankSyncIsAvailableWithoutExperimentalSettings() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        for (index, (theme, suffix)) in [("Actual Purple (light)", "light"), ("Actual Purple (dark)", "dark")].enumerated() {
            app.launchArguments = ["-actualist-demo"] + (index == 0 ? ["-actualist-replace-demo-for-ui-testing"] : []) + ["-actualist-screen", "settings/appearance"]
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

            app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/developer"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Developer"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts["Experimental Features"].exists)
            XCTAssertFalse(app.switches["Background Bank Sync"].exists)
            let developer = XCTAttachment(screenshot: app.screenshot())
            developer.name = "developer-\(suffix)"
            developer.lifetime = .keepAlways
            add(developer)
            app.terminate()
        }
    }

    /// The demo budget's accounts shown linked to SimpleFIN and Enable Banking through the
    /// screen's DEBUG preview seam (`-actualist-bank-sync-preview`), in light and dark.
    func testBankSyncShowsSimpleFINAndEnableBankingAccounts() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        for (index, (theme, suffix)) in [("Actual Purple (light)", "light"), ("Actual Purple (dark)", "dark")].enumerated() {
            app.launchArguments = ["-actualist-demo"] + (index == 0 ? ["-actualist-replace-demo-for-ui-testing"] : []) + ["-actualist-screen", "settings/appearance"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch.tap()
            app.buttons[theme].tap()
            app.terminate()

            app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/budget-data/bank-sync", "-actualist-bank-sync-preview"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Bank Sync"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["Provider, SimpleFIN and Enable Banking"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.switches["Background Bank Sync"].isEnabled)
            XCTAssertTrue(app.buttons["Sync All"].isEnabled)
            XCTAssertFalse(app.staticTexts["SimpleFIN Token"].exists)
            let top = XCTAttachment(screenshot: app.screenshot())
            top.name = "bank-sync-mixed-\(suffix)"
            top.lifetime = .keepAlways
            add(top)

            let reconnect = app.staticTexts["Reconnect in Actual web app"].firstMatch
            for _ in 0..<4 where !reconnect.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(reconnect.exists)
            let accounts = XCTAttachment(screenshot: app.screenshot())
            accounts.name = "bank-sync-mixed-accounts-\(suffix)"
            accounts.lifetime = .keepAlways
            add(accounts)
            app.terminate()
        }
    }
}
