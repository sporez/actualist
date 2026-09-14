import XCTest

final class AccountReconciliationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testAccountReconciliationOpensTargetSheetAndBalancedPanel() throws {
        let app = launchCheckingAccount()
        openReconciliationTarget(in: app)

        XCTAssertTrue(app.navigationBars["Reconcile"].waitForExistence(timeout: 5))
        let targetField = app.descendants(matching: .any)["reconciliation-target-field"]
        XCTAssertTrue(targetField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cleared balance"].exists)
        XCTAssertTrue(app.staticTexts["Last reconciled"].exists)

        let targetAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        targetAttachment.name = "account-reconciliation-target-sheet"
        targetAttachment.lifetime = .keepAlways
        add(targetAttachment)

        let start = app.buttons["reconciliation-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        start.tap()

        XCTAssertTrue(app.staticTexts["Reconciling"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Target"].exists)
        XCTAssertTrue(app.staticTexts["Cleared"].exists)
        XCTAssertTrue(app.staticTexts["Difference"].exists)
        XCTAssertTrue(app.buttons["reconciliation-lock-button"].waitForExistence(timeout: 3))

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "account-reconciliation-balanced-panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testUnlockingReconciledTransactionRequiresConfirmationAndKeepsItCleared() throws {
        let app = launchCheckingAccount()
        openReconciliationTarget(in: app)

        let start = app.buttons["reconciliation-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()

        let lock = app.buttons["reconciliation-lock-button"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        XCTAssertTrue(lock.isEnabled)
        lock.tap()
        XCTAssertTrue(lock.waitForNonExistence(timeout: 5))

        let search = app.buttons["Search Transactions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let searchField = app.textFields["Search Transactions"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Payroll Inc")

        let paycheck = app.staticTexts["Payroll Inc"].firstMatch
        XCTAssertTrue(paycheck.waitForExistence(timeout: 5))
        paycheck.tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 5))

        let cleared = app.switches["Cleared"]
        XCTAssertTrue(cleared.waitForExistence(timeout: 5))
        XCTAssertEqual(cleared.value as? String, "1")
        cleared.tap()

        let confirmation = app.staticTexts["Unlock Reconciled Transaction?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Unlock Transaction"].exists)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "reconciled-transaction-unlock-confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["Unlock Transaction"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertEqual(cleared.value as? String, "1")

        cleared.tap()
        let clearedPredicate = NSPredicate(format: "value == '0'")
        expectation(for: clearedPredicate, evaluatedWith: cleared)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(confirmation.exists)
    }

    @MainActor
    private func launchCheckingAccount() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
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

    @MainActor
    private func openReconciliationTarget(in app: XCUIApplication) {
        let accountActions = app.buttons["Account Actions"]
        XCTAssertTrue(accountActions.waitForExistence(timeout: 5))
        accountActions.tap()
        let reconcile = app.buttons["Reconcile"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 3))
        reconcile.tap()
        XCTAssertTrue(app.navigationBars["Reconcile"].waitForExistence(timeout: 5))
    }
}
