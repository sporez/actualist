import XCTest

@MainActor
final class NotesDisclosureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testMarkdownHelpPreservesDraftInDarkMode() throws {
        try exerciseHelp(theme: "Actual Purple (dark)", suffix: "dark")
    }

    @MainActor func testMarkdownHelpPreservesDraftInLightMode() throws {
        try exerciseHelp(theme: "Actual Purple (light)", suffix: "light")
    }

    @MainActor private func exerciseHelp(theme: String, suffix: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        picker.tap()
        XCTAssertTrue(app.buttons[theme].waitForExistence(timeout: 5))
        app.buttons[theme].tap()
        app.terminate()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        app.launch()
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        let monthActions = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', month actions'")).firstMatch
        if monthActions.exists {
            monthActions.tap()
        } else {
            app.buttons["Budget Actions"].tap()
        }
        app.buttons["Notes"].tap()
        let editor = app.textViews["entity-notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let help = app.buttons["notes-markdown-help"]
        XCTAssertTrue(help.exists)
        XCTAssertFalse(app.staticTexts["**bold** → Bold"].exists)
        capture("notes-collapsed-\(suffix)", app: app)
        editor.tap()
        editor.typeText("Draft **bold** and *italic*")
        let draft = editor.value as? String
        help.tap()
        XCTAssertTrue(app.staticTexts["**bold** → Bold"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["*italic* → Italic"].exists)
        XCTAssertEqual(editor.value as? String, draft)
        capture("notes-expanded-\(suffix)", app: app)
        help.tap()
        XCTAssertTrue(app.staticTexts["**bold** → Bold"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, draft)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
