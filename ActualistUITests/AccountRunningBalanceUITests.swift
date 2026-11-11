import XCTest

@MainActor
final class AccountRunningBalanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRunningBalanceTogglesFromAccountActions() throws {
        let app = launchCheckingAccount()
        XCTAssertEqual(balanceLines(in: app).count, 0)

        tapActionsItem("Show Running Balance", in: app)
        XCTAssertTrue(balanceLines(in: app).firstMatch.waitForExistence(timeout: 5))

        tapActionsItem("Hide Running Balance", in: app)
        let gone = NSPredicate(format: "count == 0")
        expectation(for: gone, evaluatedWith: balanceLines(in: app))
        waitForExpectations(timeout: 5)
    }

    /// A row's button merges its children into one element, so the balance
    /// line is found by its own identifier or through the row's label.
    private func balanceLines(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'transaction-running-balance-' "
                + "OR (identifier BEGINSWITH 'transaction-row-' AND label CONTAINS 'Balance ')"
        ))
    }

    private func tapActionsItem(_ title: String, in app: XCUIApplication) {
        let accountActions = app.buttons["Account Actions"]
        XCTAssertTrue(accountActions.waitForExistence(timeout: 5))
        accountActions.tap()
        let item = app.buttons["account-running-balance-toggle"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        XCTAssertEqual(item.label, title)
        item.tap()
    }

    private func launchCheckingAccount() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "accounts",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 15))

        let checking = app.staticTexts["Everyday Checking"].firstMatch
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        checking.tap()
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))
        return app
    }
}
