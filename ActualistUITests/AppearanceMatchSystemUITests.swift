import XCTest

@MainActor
final class AppearanceMatchSystemUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMatchSystemShowsBothPickersAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-replace-demo-for-ui-testing", "-actualist-screen", "settings/appearance"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))

        let toggle = app.switches["appearance-match-system"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()

        XCTAssertTrue(lightPicker(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(darkPicker(in: app).exists)
        XCTAssertFalse(fixedPicker(in: app).exists)
        attachScreenshot(named: "appearance-match-system-on", app: app)
        app.terminate()

        app.launchArguments = ["-actualist-screen", "settings/appearance"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.switches["appearance-match-system"].value as? String, "1")
        XCTAssertTrue(lightPicker(in: app).exists)
        XCTAssertTrue(darkPicker(in: app).exists)

        app.switches["appearance-match-system"].tap()
        XCTAssertTrue(fixedPicker(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(lightPicker(in: app).exists)
        XCTAssertFalse(darkPicker(in: app).exists)
    }

    private func fixedPicker(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
    }

    private func lightPicker(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Light Theme'")).firstMatch
    }

    private func darkPicker(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dark Theme'")).firstMatch
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
