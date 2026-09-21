import XCTest

@MainActor
final class CategoryLifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompactCreateAndReorderChrome() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact native window") }
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        attachScreenshot(named: "category-lifecycle-compact-budget")

        let group = app.buttons["budget-group-essentials"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reorder"].exists)
        XCTAssertTrue(app.buttons["budget-group-delete-essentials"].exists)
        app.buttons["Rename"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        app.buttons["Budget Actions"].tap()
        XCTAssertTrue(app.buttons["budget-new-category"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-new-group"].exists)
        app.buttons["budget-new-category"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["budget-category-lifecycle-name"].exists)
        XCTAssertTrue(app.buttons["budget-category-lifecycle-group"].exists)
        app.buttons["Cancel"].tap()

        let category = app.buttons["budget-category-rent"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-rename-rent"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-category-reorder-rent"].exists)
        XCTAssertTrue(app.buttons["budget-category-delete-rent"].exists)
        app.buttons["budget-category-reorder-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-category-rent"].exists)
        XCTAssertTrue(app.buttons["budget-category-reorder-save"].exists)
        attachScreenshot(named: "category-lifecycle-compact-reorder")
        app.buttons["budget-category-reorder-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForNonExistence(timeout: 5))

        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-reorder-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-reorder-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-delete-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-delete-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-delete-sheet"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["budget-category-delete-destination"].exists)
        XCTAssertFalse(app.buttons["budget-category-delete-confirm"].isEnabled)
        attachScreenshot(named: "category-lifecycle-compact-delete")
        app.buttons["Cancel"].tap()
    }

    func testWideCreateRenameAndReorderChrome() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        guard app.frame.width >= 792 else { throw XCTSkip("Requires a wide native window") }
        XCTAssertTrue(app.descendants(matching: .any)["budget-grid"].waitForExistence(timeout: 15))

        let group = app.buttons["budget-grid-group-essentials"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        group.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reorder"].exists)
        XCTAssertTrue(app.buttons["budget-grid-group-delete-essentials"].exists)
        app.buttons["Rename"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        app.buttons["Budget Actions"].tap()
        XCTAssertTrue(app.buttons["budget-new-category"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-new-group"].exists)
        app.buttons["budget-new-group"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        let category = app.buttons["budget-grid-category-rent"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-grid-category-rename-rent"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-grid-category-reorder-rent"].exists)
        XCTAssertTrue(app.buttons["budget-grid-category-delete-rent"].exists)
        attachScreenshot(named: "category-lifecycle-wide-delete-menu")
        app.buttons["budget-grid-category-reorder-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-category-rent"].exists)
        app.buttons["Cancel"].tap()
    }

    func testSampleValuesHideCategoryLifecycleActions() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launchDemo()
        let isWide = app.frame.width >= 792
        app.terminate()

        app = launchDemo(screen: "settings/privacy", replaceDemo: false)
        let sampleValues = app.switches["Use Sample Values"]
        XCTAssertTrue(sampleValues.waitForExistence(timeout: 5))
        if sampleValues.value as? String == "0" {
            sampleValues.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(sampleValues.value as? String, "1")
        app.terminate()

        app = launchDemo(replaceDemo: false)
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 10))
        app.buttons["Budget Actions"].tap()
        XCTAssertFalse(app.buttons["budget-new-category"].exists)
        XCTAssertFalse(app.buttons["budget-new-group"].exists)
        app.tap()

        let group = app.buttons[isWide ? "budget-grid-group-essentials" : "budget-group-essentials"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Notes"].waitForExistence(timeout: 3))
        let prefix = isWide ? "budget-grid-group" : "budget-group"
        XCTAssertFalse(app.buttons["\(prefix)-rename-essentials"].exists)
        XCTAssertFalse(app.buttons["\(prefix)-reorder-essentials"].exists)
        XCTAssertFalse(app.buttons["\(prefix)-delete-essentials"].exists)
        app.terminate()

        app = launchDemo(screen: "settings/privacy", replaceDemo: false)
        let restore = app.switches["Use Sample Values"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        if restore.value as? String == "1" {
            restore.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(restore.value as? String, "0")
    }

    private func launchDemo(
        screen: String = "budget",
        replaceDemo: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        if replaceDemo {
            app.launchArguments.append("-actualist-replace-demo-for-ui-testing")
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
