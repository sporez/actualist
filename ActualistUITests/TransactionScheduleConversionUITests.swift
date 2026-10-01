import XCTest

@MainActor
final class TransactionScheduleConversionUITests: XCTestCase {
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

    func testFutureTransactionConversionOpensOnlyFromLongPressAndCanBeCanceled() throws {
        try exerciseConversionReview(
            theme: "Actual Purple (dark)",
            dynamicType: nil,
            screenshotName: "schedule-conversion-review-dark"
        )
    }

    func testFutureTransactionConversionReviewSupportsLightAccessibilityText() throws {
        needsThemeRestoration = true
        try exerciseConversionReview(
            theme: "Actual Purple (light)",
            dynamicType: "UICTContentSizeCategoryAccessibilityXXXL",
            screenshotName: "schedule-conversion-review-light-accessibility"
        )
    }

    private func exerciseConversionReview(
        theme: String,
        dynamicType: String?,
        screenshotName: String
    ) throws {
        let app = launchFreshAccountsDemo(theme: theme, dynamicType: dynamicType)
        openCheckingAccount(in: app)

        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 10))
        addTransaction.tap()
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5))
        let amount = app.descendants(matching: .any)["transaction-amount-field"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("1")
        app.scrollViews["transaction-editor-scroll"].swipeDown()

        let payee = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Payee'")).firstMatch
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        payee.tap()
        let payeePicker = app.navigationBars["Payee"]
        XCTAssertTrue(payeePicker.waitForExistence(timeout: 5))
        let search = app.textFields["Search or enter custom payee"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Fresh Market")
        let freshMarket = app.buttons["Fresh Market"]
        XCTAssertTrue(freshMarket.waitForExistence(timeout: 5))
        freshMarket.tap()
        XCTAssertTrue(payeePicker.waitForNonExistence(timeout: 5))

        let datePicker = app.buttons["transaction-date-picker"]
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        datePicker.tap()
        let future = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: Date()))
        let currentMonth = Calendar.current.component(.month, from: Date())
        let futureMonth = Calendar.current.component(.month, from: future)
        if currentMonth != futureMonth {
            let nextMonth = app.datePickers.buttons["Next Month"]
            XCTAssertTrue(nextMonth.waitForExistence(timeout: 5))
            nextMonth.tap()
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d"
        let futureDay = app.datePickers.buttons.matching(
            NSPredicate(format: "label == %@", formatter.string(from: future))
        ).firstMatch
        XCTAssertTrue(futureDay.waitForExistence(timeout: 5))
        futureDay.tap()

        let noteText = "Schedule conversion synthetic row"
        app.scrollViews["transaction-editor-scroll"].swipeUp()
        let notes = app.textFields["transaction-notes-field"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertTrue(notes.isHittable)
        notes.tap()
        notes.typeText(noteText)
        app.scrollViews["transaction-editor-scroll"].swipeDown()

        let save = app.buttons["transaction-save-button"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "Synthetic transaction must meet the editor's save requirements")
        save.tap()
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForNonExistence(timeout: 10))

        let row = app.buttons.containing(.staticText, identifier: noteText).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "transaction-convert-to-schedule-")
        ).firstMatch.exists)

        row.press(forDuration: 1)
        let convert = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "transaction-convert-to-schedule-")
        ).firstMatch
        XCTAssertTrue(convert.waitForExistence(timeout: 5))
        convert.tap()

        let review = app.descendants(matching: .any)["transaction-schedule-conversion-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Convert Future Transaction"].exists)
        attachScreenshot(named: "\(screenshotName)-\(layoutName(in: app))", app: app)
        let reviewScroll = app.scrollViews.containing(
            .staticText, identifier: "Convert Future Transaction"
        ).firstMatch
        XCTAssertTrue(reviewScroll.waitForExistence(timeout: 5))
        let account = reviewScroll.staticTexts["Everyday Checking"]
        for _ in 0..<6 where !account.isHittable {
            reviewScroll.swipeUp()
        }
        XCTAssertTrue(account.isHittable, "The reviewed account must be reachable by scrolling")
        attachScreenshot(named: "\(screenshotName)-account-\(layoutName(in: app))", app: app)
        XCTAssertTrue(app.buttons["transaction-schedule-conversion-cancel"].isHittable)
        app.buttons["transaction-schedule-conversion-cancel"].tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Edit Transaction"].exists)
        app.terminate()
    }

    private func launchFreshAccountsDemo(
        theme: String,
        dynamicType: String?
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        prepareTheme(theme, replaceDemo: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-screen", "accounts",
        ]
        if let dynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicType]
        }
        app.launch()
        XCTAssertTrue(waitForSurface("Accounts", in: app))
        return app
    }

    private func openCheckingAccount(in app: XCUIApplication) {
        if app.collectionViews["Sidebar"].exists {
            let checking = app.collectionViews["Sidebar"].staticTexts["Everyday Checking"]
            XCTAssertTrue(checking.waitForExistence(timeout: 8))
            checking.tap()
        } else {
            let checking = app.buttons["account-row-checking"]
            XCTAssertTrue(checking.waitForExistence(timeout: 8))
            checking.tap()
        }
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))
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
        app.tabBars.firstMatch.exists ? "compact" : "wide"
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
