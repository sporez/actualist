import XCTest

@MainActor
final class CustomHeadersUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testDraftSaveMaskingAndDeletionInDarkMode() throws {
        try exerciseEditor(theme: "Actual Purple (dark)", suffix: "dark")
    }

    @MainActor func testDraftSaveMaskingAndDeletionInLightMode() throws {
        try exerciseEditor(theme: "Actual Purple (light)", suffix: "light")
    }

    @MainActor private func exerciseEditor(theme: String, suffix: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        picker.tap()
        app.buttons[theme].tap()
        app.terminate()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/connection"]
        app.launch()
        // Erase only the bundled demo, never a real simulator budget.
        XCTAssertTrue(app.staticTexts["Local demo — no server, no sync"].waitForExistence(timeout: 15))
        app.buttons["Exit Demo Mode"].tap()
        XCTAssertTrue(app.staticTexts["Exit Demo Mode?"].waitForExistence(timeout: 5))
        let confirm = try XCTUnwrap(app.buttons.matching(identifier: "Exit Demo Mode").allElementsBoundByIndex.first { $0.isHittable })
        confirm.tap()
        let server = app.textFields.firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Custom Headers"].isEnabled)
        server.tap()
        server.typeText("https://headers.example")
        let loginAttachment = XCTAttachment(screenshot: app.screenshot())
        loginAttachment.name = "onboarding-server-\(suffix)"
        loginAttachment.lifetime = .keepAlways
        add(loginAttachment)
        app.swipeUp()
        let headers = app.buttons["Custom Headers"]
        XCTAssertTrue(headers.waitForExistence(timeout: 5))
        XCTAssertTrue(headers.isEnabled)
        headers.tap()
        XCTAssertTrue(app.navigationBars["Custom Headers"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fallback Server"].exists)
        XCTAssertFalse(app.staticTexts["Primary Server"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Add Header").count, 1)
        app.buttons["Add Header"].firstMatch.tap()
        let name = app.textFields["Header Name"].firstMatch
        name.tap()
        name.typeText("X-Proxy-Token")
        let value = app.secureTextFields["Value"].firstMatch
        XCTAssertTrue(value.exists)
        value.tap()
        value.typeText("sample-credential")
        app.buttons["Show Header Value"].firstMatch.tap()
        let revealed = app.textFields["Value"].firstMatch
        XCTAssertTrue(revealed.waitForExistence(timeout: 5))
        XCTAssertEqual(revealed.value as? String, "sample-credential")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "custom-headers-populated-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
        revealed.tap()
        revealed.typeText("-edited")
        app.buttons["Hide Header Value"].firstMatch.tap()
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertFalse(revealed.exists)
        app.navigationBars["Custom Headers"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Custom Headers"].waitForNonExistence(timeout: 5))
        headers.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "X-Proxy-Token")
        XCTAssertTrue(app.secureTextFields["Value"].firstMatch.exists)
        XCTAssertFalse(app.textFields["Value"].firstMatch.exists)
        app.buttons["Show Header Value"].firstMatch.tap()
        XCTAssertTrue(revealed.waitForExistence(timeout: 5))
        XCTAssertEqual(revealed.value as? String, "sample-credential-edited")
        app.buttons["Hide Header Value"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["sample-credential"].exists)
        name.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        app.navigationBars["Custom Headers"].buttons["Save"].tap()
        headers.tap()
        XCTAssertTrue(app.navigationBars["Custom Headers"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Header Name"].firstMatch.exists)
        app.navigationBars["Custom Headers"].buttons["Cancel"].tap()
    }
}
