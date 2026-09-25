import XCTest

@MainActor
final class CredentialRecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testUnavailableWithoutCacheRetriesToNormalOnboarding() {
        let app = launch("uncached")
        XCTAssertTrue(app.staticTexts["Saved credentials unavailable"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["Server URL"].exists)
        capture("credential-blocked-iphone-dark", app: app)
        app.buttons["credentialRecoveryRetry"].tap()
        XCTAssertTrue(app.textFields["Server URL"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Saved credentials unavailable"].exists)
    }

    func testCachedBudgetStaysOpenAndRetryRemovesWarning() {
        let app = launch("cached", screen: "settings/connection")
        XCTAssertTrue(app.navigationBars["Connection & Sync"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["credentialRecoveryRetry"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Demo Mode"].exists)
        capture("credential-cached-iphone-dark", app: app)
        app.buttons["credentialRecoveryRetry"].tap()
        XCTAssertFalse(app.buttons["credentialRecoveryRetry"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Connection & Sync"].exists)
        XCTAssertTrue(app.staticTexts["Status, Connected"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Status, Offline"].exists)
    }

    func testLightRecoveryAndNormalOnboarding() {
        let blocked = launch("uncached", light: true)
        XCTAssertTrue(blocked.staticTexts["Saved credentials unavailable"].waitForExistence(timeout: 15))
        capture("credential-blocked-iphone-light", app: blocked)
        blocked.terminate()

        let cached = launch("cached", screen: "settings/connection", light: true)
        XCTAssertTrue(cached.buttons["credentialRecoveryRetry"].waitForExistence(timeout: 20))
        capture("credential-cached-iphone-light", app: cached)
        cached.terminate()

        let onboarding = launch("onboarding")
        XCTAssertTrue(onboarding.textFields["Server URL"].waitForExistence(timeout: 15))
        XCTAssertTrue(onboarding.buttons["Demo"].exists)
    }

    func testWideRecoveryPresentation() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch("uncached")
        XCTAssertTrue(app.staticTexts["Saved credentials unavailable"].waitForExistence(timeout: 15))
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "A saved credential on this device")
        ).firstMatch
        XCTAssertTrue(explanation.exists)
        XCTAssertLessThanOrEqual(explanation.frame.maxX, app.frame.maxX)
        capture("credential-blocked-ipad-dark", app: app)
        app.buttons["credentialRecoveryRetry"].tap()
        XCTAssertTrue(app.textFields["Server URL"].waitForExistence(timeout: 15))
        app.terminate()

        let light = launch("uncached", light: true)
        XCTAssertTrue(light.staticTexts["Saved credentials unavailable"].waitForExistence(timeout: 15))
        capture("credential-blocked-ipad-light", app: light)
    }

    private func launch(_ mode: String, screen: String? = nil, light: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-test-credential-session", mode]
        if light { app.launchArguments.append("light") }
        if let screen { app.launchArguments += ["-actualist-screen", screen] }
        app.launch()
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
