import XCTest

@MainActor
final class BudgetGroupExpansionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Collapse state is a per-device setting, so it outlives this test in the
    /// simulator install. The teardown re-expands Essentials even after a
    /// failure, because other Budget tests expect its rows.
    func testCollapsedGroupStaysCollapsedAfterRelaunch() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launchDemo()
        try requireCompactLayout(app, wideCoverage: "BudgetGroupExpansionTests.wideToggleIsSharedWithCompactThroughTheStore")
        addTeardownBlock { @MainActor in
            let current = XCUIApplication()
            let group = current.buttons["budget-group-essentials"]
            if group.exists, !current.buttons["budget-category-rent"].exists { group.tap() }
        }

        let group = app.buttons["budget-group-essentials"]
        let rent = app.buttons["budget-category-rent"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        if !rent.waitForExistence(timeout: 2) { group.tap() }
        XCTAssertTrue(rent.waitForExistence(timeout: 5))

        group.tap()
        XCTAssertTrue(rent.waitForNonExistence(timeout: 5))

        app.terminate()
        app = launchDemo()
        let relaunchedGroup = app.buttons["budget-group-essentials"]
        XCTAssertTrue(relaunchedGroup.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["budget-category-rent"].waitForExistence(timeout: 2))

        relaunchedGroup.tap()
        XCTAssertTrue(app.buttons["budget-category-rent"].waitForExistence(timeout: 5))
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }
}
