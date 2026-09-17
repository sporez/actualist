import XCTest

@MainActor
final class SettingsAccountOrderUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAccountOrderLoadsAndDismisses() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/budget-data"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Budget & Data"].waitForExistence(timeout: 15))
        let accountOrder = app.buttons.containing(.staticText, identifier: "Account Order").firstMatch
        for _ in 0..<4 where !accountOrder.isHittable { app.swipeUp() }
        XCTAssertTrue(accountOrder.isHittable)
        accountOrder.tap()
        XCTAssertTrue(app.navigationBars["Account Order"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Everyday Checking"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Loading accounts"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "account-order-loaded"
        capture.lifetime = .keepAlways
        add(capture)
        app.navigationBars["Account Order"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Budget & Data"].waitForExistence(timeout: 5))
    }
}
