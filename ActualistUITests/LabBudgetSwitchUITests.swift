import XCTest

/// Opt-in live check against the disposable lab server. Skipped unless
/// `TEST_RUNNER_ACTUAL_LAB_URL` and `TEST_RUNNER_ACTUAL_LAB_PASSWORD` are set.
/// Needs a simulator with no signed-in session (uninstall the Dev app first);
/// it leaves the app signed in to the lab server.
@MainActor
final class LabBudgetSwitchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            environment["ACTUAL_LAB_URL"] == nil || environment["ACTUAL_LAB_PASSWORD"] == nil,
            "Set TEST_RUNNER_ACTUAL_LAB_URL and TEST_RUNNER_ACTUAL_LAB_PASSWORD to run."
        )
    }

    func testDoubleTapOnPairBWhilePairAIsOpenEndsOnPairB() throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try XCTUnwrap(environment["ACTUAL_LAB_URL"])
        let password = try XCTUnwrap(environment["ACTUAL_LAB_PASSWORD"])

        let onboarding = XCUIApplication()
        onboarding.launchArguments = ["-actualist-replace-demo-for-ui-testing"]
        onboarding.launch()
        let urlField = onboarding.textFields["Server URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 20))
        urlField.tap()
        urlField.typeText(url)
        onboarding.buttons["Continue"].tap()
        let passwordField = onboarding.secureTextFields["Server Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 30))
        passwordField.tap()
        passwordField.typeText(password)
        onboarding.buttons["Connect with Password"].tap()

        let pairA = onboarding.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Lab · Pair A")).firstMatch
        XCTAssertTrue(pairA.waitForExistence(timeout: 60))
        pairA.tap()
        XCTAssertTrue(onboarding.tabBars.firstMatch.waitForExistence(timeout: 120))
        onboarding.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-actualist-screen", "settings/budget-data"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Budget & Data"].waitForExistence(timeout: 30))
        XCTAssertTrue(selected("Lab · Pair A", in: app).waitForExistence(timeout: 10))
        app.buttons["Change Budget"].tap()

        let pairB = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Lab · Pair B")).firstMatch
        XCTAssertTrue(pairB.waitForExistence(timeout: 30))
        pairB.doubleTap()

        XCTAssertTrue(selected("Lab · Pair B", in: app).waitForExistence(timeout: 120))
        XCTAssertFalse(app.buttons["Cancel"].waitForExistence(timeout: 3))
        XCTAssertFalse(selected("Lab · Pair A", in: app).exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "error")).firstMatch.exists)
    }

    private func selected(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }
}
