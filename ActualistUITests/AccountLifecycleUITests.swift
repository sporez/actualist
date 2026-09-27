import XCTest

@MainActor
final class AccountLifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAccountsRowRenameCancellationThenSaveRefreshesList() throws {
        let app = launchMutableAccounts()
        let originalName = "Everyday Checking"
        let cancelledName = "Cancelled Checking"
        let savedName = "Household Checking"

        try openOverviewRename(for: originalName, in: app)
        try replaceRenameField(expectedCurrentName: originalName, with: cancelledName, in: app)
        attachScreenshot(named: "account-lifecycle-row-rename-cancel-\(layoutName(for: app))", app: app)
        app.navigationBars["Rename Account"].buttons["Cancel"].tap()

        XCTAssertTrue(app.navigationBars["Rename Account"].waitForNonExistence(timeout: 5))
        let cancelledRow = accountOverviewButton(
            accountID: "checking", expectedName: originalName, in: app
        )
        XCTAssertFalse(cancelledRow.label.contains(cancelledName))

        try openOverviewRename(for: originalName, in: app)
        try replaceRenameField(expectedCurrentName: originalName, with: savedName, in: app)
        try submitRename(in: app)

        let savedRow = accountOverviewButton(accountID: "checking", expectedName: savedName, in: app)
        XCTAssertFalse(savedRow.label.contains(originalName))
        attachScreenshot(named: "account-lifecycle-row-renamed-\(layoutName(for: app))", app: app)
    }

    func testAccountDetailMenuSupportsRepeatedRenameAndRefreshesHeaderAndList() throws {
        let app = launchMutableAccounts(theme: "Actual Purple (light)")
        defer {
            app.terminate()
            restoreTheme("Actual Purple (dark)")
        }
        let originalName = "Everyday Checking"
        let firstName = "Primary Checking"
        let secondName = "Daily Checking"

        try openAccountDetail(named: originalName, in: app)
        try openDetailRename(in: app)
        try replaceRenameField(expectedCurrentName: originalName, with: firstName, in: app)
        attachScreenshot(named: "account-lifecycle-detail-rename-light-\(layoutName(for: app))", app: app)
        try submitRename(in: app)
        XCTAssertTrue(app.navigationBars[firstName].waitForExistence(timeout: 8))

        try openDetailRename(in: app)
        try replaceRenameField(expectedCurrentName: firstName, with: secondName, in: app)
        try submitRename(in: app)
        XCTAssertTrue(app.navigationBars[secondName].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars[firstName].exists)

        try returnToAccountsOverview(from: secondName, in: app)
        let finalRow = accountOverviewButton(accountID: "checking", expectedName: secondName, in: app)
        XCTAssertFalse(finalRow.label.contains(originalName))
        XCTAssertFalse(finalRow.label.contains(firstName))
        attachScreenshot(named: "account-lifecycle-detail-renamed-twice-light-\(layoutName(for: app))", app: app)
    }

    func testClosedAccountReopenPreservesOffBudgetMembership() throws {
        let app = launchMutableAccounts()
        let closedSection = sectionButton(beginningWith: "Closed (1)", in: app)
        XCTAssertTrue(closedSection.waitForExistence(timeout: 10))
        closedSection.tap()

        let carLoan = accountOverviewButton(accountID: "carloan", expectedName: "Car Loan", in: app)
        XCTAssertTrue(carLoan.waitForExistence(timeout: 5))
        openOverviewActions(accountID: "carloan", in: app)

        let reopenAction = app.buttons["account-lifecycle-reopen-action"]
        XCTAssertTrue(reopenAction.waitForExistence(timeout: 5))
        XCTAssertTrue(reopenAction.isEnabled)
        reopenAction.tap()

        XCTAssertTrue(app.navigationBars["Reopen Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Car Loan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "This account will return to the open account list with its existing history and settings."
        ].exists)
        let reopenButton = app.buttons["account-lifecycle-reopen-button"]
        XCTAssertTrue(reopenButton.waitForExistence(timeout: 5))
        XCTAssertTrue(reopenButton.isEnabled)
        attachScreenshot(named: "account-lifecycle-reopen-sheet-\(layoutName(for: app))", app: app)
        reopenButton.tap()

        XCTAssertTrue(app.navigationBars["Reopen Account"].waitForNonExistence(timeout: 8))
        let offBudgetSection = sectionButton(beginningWith: "Off Budget", in: app)
        XCTAssertTrue(offBudgetSection.waitForExistence(timeout: 8))
        let reopened = accountOverviewButton(accountID: "carloan", expectedName: "Car Loan", in: app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(reopened.frame.minY, offBudgetSection.frame.maxY)
        XCTAssertTrue(closedSection.waitForNonExistence(timeout: 5))
        attachScreenshot(named: "account-lifecycle-reopened-off-budget-\(layoutName(for: app))", app: app)
    }

    func testSampleValuesDisableRenameAndReopenActions() throws {
        let privacy = launchDemo(screen: "settings/privacy", replaceDemo: true)
        setSampleValues(true, in: privacy)
        privacy.terminate()
        defer {
            let restore = launchDemo(screen: "settings/privacy", replaceDemo: false)
            setSampleValues(false, in: restore)
            restore.terminate()
        }

        let app = launchDemo(screen: "accounts", replaceDemo: false)
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 15))
        if isWide(app) {
            let sidebar = app.collectionViews["Sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            let closed = sidebar.buttons["Closed"]
            XCTAssertTrue(closed.waitForExistence(timeout: 5))
            closed.tap()
            XCTAssertFalse(sidebar.staticTexts["Car Loan"].exists)
        }
        XCTAssertFalse(app.staticTexts["Everyday Checking"].exists)
        XCTAssertFalse(app.staticTexts["Car Loan"].exists)

        let checking = accountOverviewButton(accountID: "checking", in: app)
        XCTAssertTrue(checking.waitForExistence(timeout: 8))
        XCTAssertFalse(checking.label.contains("Everyday Checking"))
        openOverviewActions(accountID: "checking", in: app)
        let disabledRename = app.buttons["account-lifecycle-rename-action"]
        XCTAssertTrue(disabledRename.waitForExistence(timeout: 5))
        XCTAssertFalse(disabledRename.isEnabled)
        dismissMenu(in: app)

        let closedSection = sectionButton(beginningWith: "Closed (1)", in: app)
        XCTAssertTrue(closedSection.waitForExistence(timeout: 5))
        closedSection.tap()
        let carLoan = accountOverviewButton(accountID: "carloan", in: app)
        XCTAssertTrue(carLoan.waitForExistence(timeout: 5))
        XCTAssertFalse(carLoan.label.contains("Car Loan"))
        openOverviewActions(accountID: "carloan", in: app)

        let closedRename = app.buttons["account-lifecycle-rename-action"]
        let disabledReopen = app.buttons["account-lifecycle-reopen-action"]
        XCTAssertTrue(closedRename.waitForExistence(timeout: 5))
        XCTAssertTrue(disabledReopen.waitForExistence(timeout: 5))
        XCTAssertFalse(closedRename.isEnabled)
        XCTAssertFalse(disabledReopen.isEnabled)
        XCTAssertFalse(app.navigationBars["Rename Account"].exists)
        XCTAssertFalse(app.navigationBars["Reopen Account"].exists)
        attachScreenshot(named: "account-lifecycle-sample-values-gating-\(layoutName(for: app))", app: app)
    }

    private func launchMutableAccounts(theme: String? = nil) -> XCUIApplication {
        let privacy = launchDemo(screen: "settings/privacy", replaceDemo: true)
        setSampleValues(false, in: privacy)
        privacy.terminate()

        if let theme {
            let appearance = launchDemo(screen: "settings/appearance", replaceDemo: false)
            selectTheme(theme, in: appearance)
            appearance.terminate()
        }

        let app = launchDemo(screen: "accounts", replaceDemo: false)
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 15))
        return app
    }

    private func launchDemo(screen: String, replaceDemo: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        if replaceDemo {
            app.launchArguments.append("-actualist-replace-demo-for-ui-testing")
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func openOverviewRename(for accountName: String, in app: XCUIApplication) throws {
        let account = accountOverviewButton(
            accountID: "checking", expectedName: accountName, in: app
        )
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        openOverviewActions(accountID: "checking", in: app)
        let rename = app.buttons["account-lifecycle-rename-action"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertTrue(rename.isEnabled)
        rename.tap()
        XCTAssertTrue(app.navigationBars["Rename Account"].waitForExistence(timeout: 5))
    }

    private func openAccountDetail(named accountName: String, in app: XCUIApplication) throws {
        if isWide(app) {
            let sidebar = app.collectionViews["Sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
            let account = sidebar.staticTexts[accountName]
            XCTAssertTrue(account.waitForExistence(timeout: 5))
            account.tap()
        } else {
            let account = accountOverviewButton(
                accountID: "checking", expectedName: accountName, in: app
            )
            XCTAssertTrue(account.waitForExistence(timeout: 5))
            account.tap()
        }
        XCTAssertTrue(app.navigationBars[accountName].waitForExistence(timeout: 8))
    }

    private func openDetailRename(in app: XCUIApplication) throws {
        let actions = app.buttons["Account Actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let rename = app.buttons["account-lifecycle-rename-action"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertTrue(rename.isEnabled)
        rename.tap()
        XCTAssertTrue(app.navigationBars["Rename Account"].waitForExistence(timeout: 5))
    }

    private func replaceRenameField(
        expectedCurrentName: String,
        with replacement: String,
        in app: XCUIApplication
    ) throws {
        let field = app.textFields["account-lifecycle-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let currentValue = try XCTUnwrap(field.value as? String)
        XCTAssertEqual(currentValue, expectedCurrentName)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        field.typeText(replacement)
        XCTAssertEqual(field.value as? String, replacement)

        let rename = app.buttons["account-lifecycle-rename-button"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: rename
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    }

    private func submitRename(in app: XCUIApplication) throws {
        let rename = app.buttons["account-lifecycle-rename-button"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertTrue(rename.isEnabled)
        XCTAssertTrue(rename.isHittable)
        rename.tap()
        XCTAssertTrue(app.navigationBars["Rename Account"].waitForNonExistence(timeout: 8))
    }

    private func returnToAccountsOverview(from accountName: String, in app: XCUIApplication) throws {
        if isWide(app) {
            let sidebar = app.collectionViews["Sidebar"]
            let accounts = sidebar.cells.containing(.staticText, identifier: "Accounts").firstMatch
            XCTAssertTrue(accounts.waitForExistence(timeout: 5))
            accounts.tap()
        } else {
            let back = app.navigationBars[accountName].buttons["Accounts"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 8))
    }

    private func accountOverviewButton(
        accountID: String,
        expectedName: String? = nil,
        in app: XCUIApplication
    ) -> XCUIElement {
        let account = app.buttons["account-row-\(accountID)"]
        XCTAssertTrue(
            account.waitForExistence(timeout: 8),
            "Expected account row for \(accountID) in the Accounts overview"
        )
        if let expectedName {
            let updatedLabel = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", expectedName),
                object: account
            )
            XCTAssertEqual(XCTWaiter.wait(for: [updatedLabel], timeout: 8), .completed)
        }
        return account
    }

    private func openOverviewActions(accountID: String, in app: XCUIApplication) {
        let actions = app.buttons["account-actions-\(accountID)"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isHittable)
        actions.tap()
    }

    private func sectionButton(beginningWith title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func setSampleValues(_ enabled: Bool, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 10))
        let sampleValues = app.switches["Use Sample Values"]
        XCTAssertTrue(sampleValues.waitForExistence(timeout: 5))
        let desired = enabled ? "1" : "0"
        if sampleValues.value as? String != desired {
            sampleValues.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", desired),
            object: sampleValues
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func selectTheme(_ theme: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 10))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let choice = app.buttons[theme]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func restoreTheme(_ theme: String) {
        let appearance = launchDemo(screen: "settings/appearance", replaceDemo: false)
        selectTheme(theme, in: appearance)
        appearance.terminate()
    }

    private func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["account-lifecycle-rename-action"].waitForNonExistence(timeout: 3))
    }

    private func isWide(_ app: XCUIApplication) -> Bool {
        app.frame.width >= 792
    }

    private func layoutName(for app: XCUIApplication) -> String {
        isWide(app) ? "wide" : "compact"
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
