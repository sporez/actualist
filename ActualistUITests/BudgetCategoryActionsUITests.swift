import XCTest

/// Hide/show and rollover from a category row's context menu. The wide layout's
/// equivalent is `BudgetWorkspaceActionsTests`; the shared guard logic is
/// `BudgetCategoryFlagWorkflowTests`.
@MainActor
final class BudgetCategoryActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompactHidesThenShowsACategory() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        try requireCompactLayout(app, wideCoverage: "BudgetWorkspaceActionsTests")
        let rent = app.buttons["budget-category-rent"]
        XCTAssertTrue(rent.waitForExistence(timeout: 15))

        rent.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Hide"].waitForExistence(timeout: 3))
        app.buttons["Hide"].tap()
        XCTAssertTrue(rent.waitForNonExistence(timeout: 10))

        setShowHiddenCategories(in: app)
        XCTAssertTrue(rent.waitForExistence(timeout: 10))
        rent.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Show"].waitForExistence(timeout: 3))
        app.buttons["Show"].tap()

        // Turning the hidden filter back off must keep the now-visible category.
        setShowHiddenCategories(in: app)
        XCTAssertTrue(rent.waitForExistence(timeout: 10))
        rent.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Hide"].waitForExistence(timeout: 3))
    }

    func testCompactTogglesCarryoverBothWays() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        try requireCompactLayout(app, wideCoverage: "BudgetWorkspaceActionsTests")
        let rent = app.buttons["budget-category-rent"]
        XCTAssertTrue(rent.waitForExistence(timeout: 15))

        let first = rolloverTitle(of: rent, in: app)
        app.buttons["budget-category-rollover-rent"].tap()
        let second = rolloverTitle(of: rent, in: app, differentFrom: first)
        XCTAssertNotEqual(first, second)
        app.buttons["budget-category-rollover-rent"].tap()
        XCTAssertEqual(rolloverTitle(of: rent, in: app, differentFrom: second), first)
    }

    /// Opens the category menu, returns the current rollover action ("Roll Over"
    /// or "Stop Rolling Over") and leaves the menu open. When `other` is given,
    /// waits for the menu to show the opposite action.
    private func rolloverTitle(
        of category: XCUIElement,
        in app: XCUIApplication,
        differentFrom other: String? = nil
    ) -> String {
        let deadline = Date().addingTimeInterval(10)
        while true {
            category.press(forDuration: 1)
            let item = app.buttons["budget-category-rollover-rent"]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            let title = item.label.hasPrefix("Stop Rolling Over") ? "Stop Rolling Over" : "Roll Over"
            if other == nil || title != other || Date() > deadline { return title }
            // The write has not refreshed the row yet. Close the menu and look again.
            app.tap()
        }
    }

    private func setShowHiddenCategories(in app: XCUIApplication) {
        app.buttons["Budget Actions"].tap()
        let categories = app.buttons["Categories & Groups"]
        XCTAssertTrue(categories.waitForExistence(timeout: 3))
        categories.tap()
        let toggle = app.buttons["Show Hidden Categories"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo", "-actualist-screen", "budget",
            "-actualist-replace-demo-for-ui-testing"
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }
}
