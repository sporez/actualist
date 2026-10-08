import XCTest

@MainActor
final class TransactionCommandUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMergeAppearsOnlyWhenTwoTransactionsAreSelected() throws {
        let app = launchFreshSpendingDemo()
        selectTransactions(["din-00151"], in: app)
        app.buttons["transaction-selection-actions"].tap()
        XCTAssertTrue(app.buttons["Duplicate Transactions…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Merge Transactions…"].exists)
    }

    func testMergeReviewLabelsInputsInTapOrder() throws {
        let app = launchFreshSpendingDemo()
        selectTransactions(["pay-00140", "pay-00139"], in: app)
        openMergeReview(in: app)

        XCTAssertTrue(app.staticTexts["Review Merge Transactions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["transaction-merge-input-1-pay-00140"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["transaction-merge-input-2-pay-00139"].exists)
        XCTAssertTrue(app.staticTexts["Input 1"].exists)
        XCTAssertTrue(app.staticTexts["Input 2"].exists)
        attachScreenshot(named: "merge-input-order-\(layoutName(in: app))", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["transaction-selection-count"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transaction-selection-count"].label.contains("2"))
    }

    func testMergeReviewShowsKeptAndDroppedPreview() throws {
        let app = launchFreshSpendingDemo()
        selectTransactions(["pay-00140", "pay-00139"], in: app)
        openMergeReview(in: app)

        XCTAssertTrue(app.staticTexts["Kept"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Dropped"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["transaction-merge-kept"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["transaction-merge-dropped"].exists)
        XCTAssertTrue(app.buttons["transaction-merge-confirm"].isEnabled)
        attachScreenshot(named: "merge-kept-dropped-\(layoutName(in: app))", app: app)
        app.buttons["Cancel"].tap()
    }

    func testAmountMismatchBlocksMergeBeforeConfirmation() throws {
        let app = launchFreshSpendingDemo()
        selectTransactions(["din-00151", "groc-00144"], in: app)
        openMergeReview(in: app)

        let reason = app.descendants(matching: .any)["transaction-merge-blocked-reason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 10))
        XCTAssertTrue(reason.label.contains("different amounts"))
        XCTAssertFalse(app.buttons["transaction-merge-confirm"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["transaction-merge-reconciled-warning"].exists)
        attachScreenshot(named: "merge-blocked-amount-\(layoutName(in: app))", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["transaction-selection-done"].waitForExistence(timeout: 5))
    }

    func testBlockedChildReasonAppearsBeforeConfirmation() throws {
        let app = launchFreshSpendingDemo()
        enterSelection(in: app)
        let splitEntry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Split")
        ).firstMatch
        guard splitEntry.waitForExistence(timeout: 2) else {
            throw XCTSkip("The bundled demo has no split entry, so a child merge block cannot be driven here.")
        }
        splitEntry.tap()
        let other = app.buttons["transaction-selection-din-00151"]
        if other.exists { other.tap() }
        openMergeReview(in: app)
        let reason = app.descendants(matching: .any)["transaction-merge-blocked-reason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 10))
        XCTAssertTrue(reason.label.contains("split entry"))
        XCTAssertFalse(app.buttons["transaction-merge-confirm"].isEnabled)
    }

    func testReconciledMergeShowsConfirmationBeforeSubmit() throws {
        let app = launchFreshSpendingDemo()
        enterSelection(in: app)
        let reconciled = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reconciled")
        ).firstMatch
        guard reconciled.waitForExistence(timeout: 2) else {
            throw XCTSkip("The bundled demo has no reconciled transaction, so the confirmation warning cannot be driven here.")
        }
        reconciled.tap()
        let other = app.buttons["transaction-selection-din-00151"]
        if other.exists, !other.isSelected { other.tap() }
        openMergeReview(in: app)
        let warning = app.descendants(matching: .any)["transaction-merge-reconciled-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(warning.label.contains("reconciled transaction"))
        XCTAssertTrue(warning.label.contains("connected to these changes"))
    }

    func testDuplicateFamilyDeduplicationAppearsBeforeConfirmation() throws {
        let app = launchFreshSpendingDemo()
        enterSelection(in: app)
        let split = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Split")).firstMatch
        guard split.waitForExistence(timeout: 2) else {
            throw XCTSkip("The bundled demo has no split family, so duplicate deduplication cannot be driven here.")
        }
        split.tap()
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Duplicate Transactions…"].tap()
        let message = app.descendants(matching: .any)["transaction-duplicate-family-deduplication"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("duplicated once") || message.label.contains("one copy"))
        XCTAssertTrue(app.buttons["transaction-duplicate-confirm"].isEnabled)
    }

    func testCanceledReviewCanBePreparedAgain() throws {
        let app = launchFreshSpendingDemo()
        selectTransactions(["din-00151"], in: app)
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Duplicate Transactions…"].tap()
        XCTAssertTrue(app.staticTexts["Review Duplicate Transactions"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["transaction-selection-count"].waitForExistence(timeout: 5))
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Duplicate Transactions…"].tap()
        XCTAssertTrue(app.staticTexts["Review Duplicate Transactions"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
    }

    func testStaleReviewDoesNotReplaceTheVisibleReview() throws {
        throw XCTSkip(
            "The bundled demo cannot delay a review. TransactionDuplicateCoordinatorTests.lateDuplicateReviewDoesNotReplaceANewReview covers stale generation."
        )
    }

    func testFailurePreservesSelection() throws {
        throw XCTSkip(
            "The bundled demo cannot force a command failure. TransactionDuplicateCoordinatorTests.duplicateFailurePreservesTheSelection and TransactionMergeCoordinatorTests.mergeFailurePreservesTapOrder cover it."
        )
    }

    func testDuplicateCommitHasOneHistoryUndo() throws {
        let app = launchFreshSpendingDemo()
        selectTransactions(["din-00151"], in: app)
        app.buttons["transaction-selection-actions"].tap()
        app.buttons["Duplicate Transactions…"].tap()
        XCTAssertTrue(app.buttons["transaction-duplicate-confirm"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["transaction-duplicate-confirm"].isEnabled)
        app.buttons["transaction-duplicate-confirm"].tap()
        XCTAssertTrue(app.buttons["transaction-duplicate-confirm"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Changes Saved"].exists)
        XCTAssertTrue(app.staticTexts["transaction-selection-count"].waitForNonExistence(timeout: 10))

        openBudget(in: app)
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 10))
        app.buttons["Budget Actions"].tap()
        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))

        let undoRows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Undo Duplicated")
        )
        XCTAssertTrue(undoRows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(undoRows.count, 1)
        undoRows.firstMatch.tap()
        let confirmUndo = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "duplicate entr")
        ).firstMatch
        XCTAssertTrue(confirmUndo.waitForExistence(timeout: 5))
        attachScreenshot(named: "duplicate-history-undo-\(layoutName(in: app))", app: app)
        confirmUndo.tap()
        XCTAssertTrue(app.navigationBars["Undo Action"].waitForNonExistence(timeout: 10))
    }

    private func launchFreshSpendingDemo() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "spending",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Transaction Actions"].waitForExistence(timeout: 15))
        return app
    }

    private func enterSelection(in app: XCUIApplication) {
        app.buttons["Transaction Actions"].tap()
        app.buttons["Select Transactions"].tap()
        XCTAssertTrue(app.buttons["transaction-selection-actions"].waitForExistence(timeout: 5))
    }

    private func selectTransactions(_ ids: [String], in app: XCUIApplication) {
        enterSelection(in: app)
        for id in ids {
            let button = app.buttons["transaction-selection-\(id)"]
            XCTAssertTrue(scrollTo(button, in: app), "Missing selectable transaction \(id)")
            button.tap()
        }
        let count = app.staticTexts["transaction-selection-count"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "\(ids.count)"),
            object: count
        )
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed, "Selection count: \(count.label)")
    }

    private func openMergeReview(in app: XCUIApplication) {
        app.buttons["transaction-selection-actions"].tap()
        let merge = app.buttons["Merge Transactions…"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.tap()
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        return element.exists && element.isHittable
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
