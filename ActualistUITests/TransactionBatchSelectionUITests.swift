import XCTest

@MainActor
final class TransactionBatchSelectionUITests: XCTestCase {
    private var needsThemeRestoration = false

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    override func tearDown() async throws {
        if needsThemeRestoration {
            restoreTheme("Actual Purple (dark)")
        }
    }

    func testClearReviewCanBeCanceledWithoutLeavingSelectionMode() throws {
        let app = launchFreshSpendingDemo(theme: "Actual Purple (dark)")
        selectFirstLoadedTransaction(in: app)
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Clear Transactions"].tap()

        XCTAssertTrue(app.staticTexts["Review Clear Transactions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Selected transactions"].exists)
        XCTAssertTrue(firstExactReviewRow(in: app).waitForExistence(timeout: 5))
        attachScreenshot(named: "batch-clear-exact-review-dark-\(layoutName(in: app))", app: app)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.staticTexts["transaction-selection-count"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transaction-selection-done"].exists)
        app.buttons["transaction-selection-done"].tap()
        XCTAssertTrue(app.buttons["transaction-actions-menu"].waitForExistence(timeout: 5))
    }

    func testCategoryPickerPreparesBatchReview() throws {
        let app = launchFreshSpendingDemo(theme: "Actual Purple (dark)")
        selectFirstLoadedTransaction(in: app)
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Categorize Transactions…"].tap()

        XCTAssertTrue(app.staticTexts["Categorize Transactions"].waitForExistence(timeout: 10))
        let category = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "transaction-batch-category-")
        ).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        attachScreenshot(named: "batch-category-picker-dark-\(layoutName(in: app))", app: app)
        category.tap()

        XCTAssertTrue(app.staticTexts["Review Categorize Transactions"].waitForExistence(timeout: 10))
        XCTAssertTrue(firstExactReviewRow(in: app).waitForExistence(timeout: 5))
        attachScreenshot(named: "batch-category-exact-review-dark-\(layoutName(in: app))", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["transaction-selection-done"].waitForExistence(timeout: 5))
    }

    func testDeleteBatchReviewCanBeCanceled() throws {
        let app = launchFreshSpendingDemo()
        selectFirstLoadedTransaction(in: app)
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Delete Transactions…"].tap()

        XCTAssertTrue(app.staticTexts["Review Delete Transactions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Selected transactions"].exists)
        XCTAssertTrue(firstExactReviewRow(in: app).waitForExistence(timeout: 5))
        attachScreenshot(named: "batch-delete-exact-review-\(layoutName(in: app))", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["transaction-selection-done"].waitForExistence(timeout: 5))
    }

    func testAccountActionsEntersStableTransactionSelection() throws {
        let app = launchFreshAccountsDemo()
        if app.frame.width >= 792 {
            let checking = app.collectionViews["Sidebar"].staticTexts["Everyday Checking"]
            XCTAssertTrue(checking.waitForExistence(timeout: 8))
            checking.tap()
        } else {
            let checking = app.buttons["account-row-checking"]
            XCTAssertTrue(checking.waitForExistence(timeout: 8))
            checking.tap()
        }
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))
        app.buttons["Account Actions"].tap()
        app.buttons["Select Transactions"].tap()

        let firstTransaction = firstSelectableTransaction(in: app)
        XCTAssertTrue(firstTransaction.waitForExistence(timeout: 10))
        firstTransaction.tap()
        XCTAssertTrue(app.staticTexts["transaction-selection-count"].waitForExistence(timeout: 5))
        app.buttons["transaction-selection-done"].tap()
    }

    func testConfirmedClearHasOneHistoryUndo() throws {
        let app = launchFreshSpendingDemo()
        let transactionID = "din-00151"
        let uncleared = app.buttons["transaction-row-\(transactionID)"]
        XCTAssertTrue(uncleared.waitForExistence(timeout: 10))
        XCTAssertFalse(uncleared.label.contains("Cleared"))
        XCTAssertFalse(uncleared.label.contains("Reconciled"))
        selectFirstLoadedTransaction(in: app, transactionID: transactionID)
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Clear Transactions"].tap()
        XCTAssertTrue(app.staticTexts["Review Clear Transactions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Clear"].isEnabled)
        app.buttons["Clear"].tap()
        XCTAssertTrue(app.staticTexts["Changes Saved"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "saved"
        )).firstMatch.exists)
        attachScreenshot(named: "batch-clear-saved-dark-\(layoutName(in: app))", app: app)
        app.buttons["Done"].tap()

        openBudget(in: app)
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 10))
        app.buttons["Budget Actions"].tap()
        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))

        let undoRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Undo Cleared")
        ).firstMatch
        XCTAssertTrue(undoRow.waitForExistence(timeout: 10))
        undoRow.tap()
        XCTAssertTrue(app.navigationBars["Undo Action"].waitForExistence(timeout: 5))
        let confirmUndo = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Confirm undo of Cleared")
        ).firstMatch
        XCTAssertTrue(confirmUndo.waitForExistence(timeout: 5))
        attachScreenshot(named: "batch-clear-history-undo-dark-\(layoutName(in: app))", app: app)
        confirmUndo.tap()
        XCTAssertTrue(app.navigationBars["Undo Action"].waitForNonExistence(timeout: 10))
    }

    func testClearReviewSupportsLightAccessibilityText() throws {
        needsThemeRestoration = true
        let app = launchFreshSpendingDemo(
            theme: "Actual Purple (light)",
            dynamicType: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        selectFirstLoadedTransaction(in: app)
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Clear Transactions"].tap()

        XCTAssertTrue(app.staticTexts["Review Clear Transactions"].waitForExistence(timeout: 10))
        let reviewScroll = app.scrollViews.containing(
            .staticText, identifier: "Review Clear Transactions"
        ).firstMatch
        XCTAssertTrue(reviewScroll.waitForExistence(timeout: 5))
        let row = firstExactReviewRow(in: app)
        for _ in 0..<8 where !row.isHittable {
            reviewScroll.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "Exact review row must be reachable by scrolling")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        attachScreenshot(named: "batch-clear-exact-review-light-accessibility-\(layoutName(in: app))", app: app)
        app.buttons["Cancel"].tap()
        app.terminate()
    }

    private func launchFreshSpendingDemo(
        theme: String = "Actual Purple (dark)",
        dynamicType: String? = nil
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        prepareTheme(theme, replaceDemo: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-screen", "spending",
        ]
        if let dynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicType]
        }
        app.launch()
        XCTAssertTrue(waitForSurface("Spending", in: app))
        XCTAssertTrue(app.buttons["Transaction Actions"].waitForExistence(timeout: 10))
        return app
    }

    private func launchFreshAccountsDemo() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "accounts",
        ]
        app.launch()
        XCTAssertTrue(waitForSurface("Accounts", in: app))
        return app
    }

    private func selectFirstLoadedTransaction(in app: XCUIApplication, transactionID: String? = nil) {
        app.buttons["Transaction Actions"].tap()
        app.buttons["Select Transactions"].tap()

        let firstTransaction = transactionID.map { app.buttons["transaction-selection-\($0)"] }
            ?? firstSelectableTransaction(in: app)
        XCTAssertTrue(firstTransaction.waitForExistence(timeout: 10))
        firstTransaction.tap()
        XCTAssertTrue(app.staticTexts["transaction-selection-count"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transaction-selection-count"].label.contains("1"))
    }

    private func firstExactReviewRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "transaction-batch-review-row-")
        ).firstMatch
    }

    private func firstSelectableTransaction(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@ AND identifier != %@ AND identifier != %@",
            "transaction-selection-",
            "transaction-selection-actions",
            "transaction-selection-done",
            "transaction-selection-enter"
        )).firstMatch
    }

    private func openBudget(in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            let budget = tabBar.buttons["Budget"]
            XCTAssertTrue(budget.waitForExistence(timeout: 5))
            budget.tap()
        } else {
            let budget = app.collectionViews["Sidebar"].cells.containing(
                .staticText,
                identifier: "Budget"
            ).firstMatch
            XCTAssertTrue(budget.waitForExistence(timeout: 5))
            budget.tap()
        }
    }

    private func prepareTheme(_ theme: String, replaceDemo: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        if replaceDemo { app.launchArguments.append("-actualist-replace-demo-for-ui-testing") }
        app.launch()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        if !picker.label.contains(theme) {
            picker.tap()
            let choice = app.buttons[theme]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
        }
        app.terminate()
    }

    private func restoreTheme(_ theme: String) {
        prepareTheme(theme, replaceDemo: false)
    }

    private func waitForSurface(_ title: String, in app: XCUIApplication) -> Bool {
        let navigationBar = app.navigationBars[title]
        let sidebarItem = app.collectionViews["Sidebar"].cells.containing(
            .staticText,
            identifier: title
        ).firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in navigationBar.exists || sidebarItem.exists },
            object: nil
        )
        return XCTWaiter.wait(for: [ready], timeout: 15) == .completed
    }

    private func layoutName(in app: XCUIApplication) -> String {
        app.frame.width >= 792 ? "wide" : "compact"
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
