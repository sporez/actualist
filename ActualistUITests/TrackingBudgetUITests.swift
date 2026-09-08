import XCTest

final class TrackingBudgetUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testIncomeAssignmentAndDetails() throws {
        let app = launch()
        let wide = app.frame.width >= 792
        let income = wide ? app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-' AND identifier ENDSWITH '-paycheck'")).firstMatch : app.buttons["budget-category-paycheck"]
        XCTAssertTrue(income.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["To Budget"].exists)
        capture("tracking-income-before", app)
        income.tap()
        XCTAssertFalse(app.buttons["Move Money"].exists)
        app.buttons["1"].tap()
        app.buttons["2"].tap()
        app.buttons["3"].tap()
        app.buttons["Save assignment"].tap()
        XCTAssertTrue(income.waitForExistence(timeout: 5))
        capture("tracking-income-saved", app)
        if wide {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity-' AND identifier ENDSWITH '-paycheck'")).firstMatch.tap()
        } else {
            income.tap()
            app.buttons["Details"].tap()
        }
        XCTAssertTrue(app.staticTexts["Received"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Rollover Balance"].exists)
        capture("tracking-income-details", app)
    }

    @MainActor
    func testRolloverKeepsCategoryTransactionsVisible() throws {
        var app = launch(screen: "settings/appearance")
        let theme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 10))
        theme.tap()
        app.buttons["Actual Purple (dark)"].tap()
        app.terminate()
        app = launch()
        let month = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS '2026' AND label CONTAINS 'Sep'")).firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 15))
        month.tap()
        app.buttons["Aug"].tap()
        let groceries = app.buttons["budget-category-groceries"]
        if !groceries.isHittable { app.swipeUp() }
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        app.buttons["Details"].tap()
        let transaction = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fresh Market'")).firstMatch
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        for index in 0..<2 {
            let rollover = app.switches["Rollover Balance"]
            XCTAssertTrue(rollover.waitForExistence(timeout: 5))
            let before = rollover.value as? String ?? ""
            rollover.tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@ AND enabled == true", before), object: rollover)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            XCTAssertTrue(transaction.waitForExistence(timeout: 5))
            capture("tracking-rollover-preserved-\(index)", app)
        }
    }

    @MainActor
    func testTrackingAccessibilityLayout() throws {
        let app = launch(dynamicType: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.buttons["budget-category-paycheck"].waitForExistence(timeout: 15))
        capture("tracking-accessibility-income", app)
        app.swipeUp()
        capture("tracking-accessibility-expenses", app)
    }

    @MainActor
    func testPastMonthRolloverThemesAndPrivacy() throws {
        var app = launch()
        if app.frame.width >= 792 {
            app.buttons["Previous month"].tap()
        } else {
            app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS '2026' AND label CONTAINS 'Sep'")).firstMatch.tap()
            app.buttons["Aug"].tap()
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Saved'")).firstMatch.waitForExistence(timeout: 5))
        capture("tracking-past-month-dark", app)
        let wide = app.frame.width >= 792
        let expense = wide ? app.buttons["activity-2026-08-groceries"] : app.buttons["budget-category-groceries"]
        if !expense.isHittable { app.swipeUp() }
        XCTAssertTrue(expense.waitForExistence(timeout: 5))
        expense.tap()
        if !wide { app.buttons["Details"].tap() }
        let rollover = app.switches["Rollover Balance"]
        XCTAssertTrue(rollover.waitForExistence(timeout: 5))
        let before = rollover.value as? String
        rollover.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? ""), object: rollover)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        capture("tracking-expense-rollover", app)
        app.terminate()
        app = launch(screen: "settings/appearance")
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Actual Purple (light)"].tap()
        app.terminate()
        app = launch()
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 10))
        capture("tracking-light", app)
        app.terminate()
        app = launch(screen: "settings/privacy")
        let sample = app.switches["Use Sample Values"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        if sample.value as? String == "0" { sample.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(sample.value as? String, "1")
        app.terminate()
        app = launch()
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Paycheck"].exists)
        capture("tracking-private", app)
        app.terminate()
        app = launch(screen: "settings/privacy")
        let restore = app.switches["Use Sample Values"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        if restore.value as? String == "1" { restore.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(restore.value as? String, "0")
        app.terminate()
        app = launch(screen: "settings/appearance")
        let restoreTheme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(restoreTheme.waitForExistence(timeout: 5))
        restoreTheme.tap()
        app.buttons["Actual Purple (dark)"].tap()
    }

    @MainActor
    func testSampleDeficitReviewOpensActivityWithoutCover() throws {
        var app = launch(screen: "settings/privacy")
        let sample = app.switches["Use Sample Values"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        if sample.value as? String == "0" { sample.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(sample.value as? String, "1")
        app.terminate()
        app = launch()
        let review = app.buttons["budget-alert-overspending"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        XCTAssertTrue(app.navigationBars["Overspent Categories"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Cover"].exists)
        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'budget-overspent-'")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        capture("tracking-private-deficit-review", app)
        category.tap()
        XCTAssertTrue(app.staticTexts["Spent"].waitForExistence(timeout: 5))
        capture("tracking-private-deficit-details", app)
        app.terminate()
        app = launch(screen: "settings/privacy")
        let restore = app.switches["Use Sample Values"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        if restore.value as? String == "1" { restore.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
    }

    @MainActor
    func testTransactionPickerShowsTrackingIncomeCategories() throws {
        for theme in ["Actual Purple (light)", "Actual Purple (dark)"] {
            var app = launch(screen: "settings/appearance")
            let themePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
            XCTAssertTrue(themePicker.waitForExistence(timeout: 10))
            themePicker.tap()
            app.buttons[theme].tap()
            app.terminate()
            app = launch()
            let add = app.buttons["Add Transaction"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            let category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Category'")).firstMatch
            XCTAssertTrue(category.waitForExistence(timeout: 5))
            category.tap()
            let paycheck = app.buttons["Paycheck"]
            XCTAssertTrue(paycheck.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["To Budget"].exists)
            capture("tracking-transaction-income-\(theme)", app)
            paycheck.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Category' AND label CONTAINS 'Paycheck'")).firstMatch.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    private func launch(dynamicType: String? = nil, screen: String = "budget") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-tracking-demo", "-actualist-screen", screen]
        if let dynamicType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicType] }
        app.launch()
        if app.frame.width >= 792 {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        return app
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
