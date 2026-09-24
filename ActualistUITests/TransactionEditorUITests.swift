import XCTest

@MainActor
final class TransactionEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAmountFormatsMinorUnitsAndScrollDismissesKeyboard() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()

        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 10))
        addTransaction.tap()
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5))

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.typeText("1")
        XCTAssertTrue(formattedAmount(containing: "0.01", in: app).waitForExistence(timeout: 5))

        app.typeText("2")
        XCTAssertTrue(formattedAmount(containing: "0.12", in: app).waitForExistence(timeout: 5))

        let split = app.buttons["Split"]
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))

        let editorScroll = app.scrollViews["transaction-editor-scroll"]
        XCTAssertTrue(editorScroll.waitForExistence(timeout: 5))
        let splitAmount = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transaction-split-amount-'")
        ).firstMatch
        XCTAssertTrue(splitAmount.waitForExistence(timeout: 5))
        splitAmount.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        editorScroll.swipeDown()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Keyboard remained at \(keyboard.frame)")
    }

    func testEditorInteractionRegressionOnIPhone() throws {
        try exerciseEditorInteraction(requireWide: false)
    }

    func testEditorInteractionRegressionOnIPad() throws {
        try exerciseEditorInteraction(requireWide: true)
    }

    private func exerciseEditorInteraction(requireWide: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        let isWide = app.windows.firstMatch.frame.width > 700
        guard isWide == requireWide else {
            throw XCTSkip(requireWide ? "Requires the pinned iPad" : "Requires the pinned iPhone")
        }

        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 10))
        addTransaction.tap()
        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let editorScroll = app.scrollViews["transaction-editor-scroll"]
        XCTAssertTrue(editorScroll.waitForExistence(timeout: 5))
        captureScreenshot(named: requireWide ? "transaction-editor-ipad-start" : "transaction-editor-iphone-start")

        let amountField = app.descendants(matching: .any)["transaction-amount-field"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        waitForAmountInput(in: app)
        app.typeText("1234")
        XCTAssertTrue(formattedAmount(containing: "12.34", in: app).waitForExistence(timeout: 5))

        dismissNumberPadPopover(in: app, editor: editor)

        let payee = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Payee'")).firstMatch
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        payee.tap()
        let payeePicker = app.navigationBars["Payee"]
        XCTAssertTrue(payeePicker.waitForExistence(timeout: 5))
        let payeeSearch = app.textFields["Search or enter custom payee"]
        XCTAssertTrue(payeeSearch.waitForExistence(timeout: 5))
        payeeSearch.tap()
        payeeSearch.typeText("Fresh Market")
        let freshMarket = app.buttons["Fresh Market"]
        XCTAssertTrue(freshMarket.waitForExistence(timeout: 5))
        freshMarket.tap()
        XCTAssertTrue(payeePicker.waitForNonExistence(timeout: 5))
        assertNoEditorKeyboard(in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fresh Market'")).firstMatch.exists)

        let category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Category'")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        let categoryPicker = app.navigationBars["Category"]
        XCTAssertTrue(categoryPicker.waitForExistence(timeout: 5))
        let groceries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Groceries'"))
            .firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        XCTAssertTrue(categoryPicker.waitForNonExistence(timeout: 5))
        assertNoEditorKeyboard(in: app)

        category.tap()
        XCTAssertTrue(categoryPicker.waitForExistence(timeout: 5))
        categoryPicker.buttons.firstMatch.tap()
        XCTAssertTrue(categoryPicker.waitForNonExistence(timeout: 5))
        assertNoEditorKeyboard(in: app)

        editorScroll.swipeDown()
        let accountButton = editorScroll.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'"))
            .firstMatch
        XCTAssertTrue(accountButton.waitForExistence(timeout: 5))
        XCTAssertTrue(accountButton.isHittable, "Account Menu button was not hittable")
        accountButton.tap()
        let accountOption = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "High-Yield Savings")
        ).firstMatch
        XCTAssertTrue(accountOption.waitForExistence(timeout: 5))
        accountOption.tap()
        assertNoEditorKeyboard(in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'High-Yield Savings'")).firstMatch.exists)

        formattedAmount(containing: "12.34", in: app).tap()
        waitForAmountInput(in: app)
        app.typeText("5")
        XCTAssertTrue(formattedAmount(containing: "123.45", in: app).waitForExistence(timeout: 5))
        dismissNumberPadPopover(in: app, editor: editor)

        let datePicker = app.descendants(matching: .any)["transaction-date-picker"]
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        let originalDate = try XCTUnwrap(datePicker.value as? String)
        datePicker.tap()
        let dayNumber = originalDate.contains(" 15,") ? "16" : "15"
        let day = app.datePickers.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " \(dayNumber)")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        XCTAssertTrue(day.waitForNonExistence(timeout: 5))
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        XCTAssertNotEqual(datePicker.value as? String, originalDate)
        assertNoEditorKeyboard(in: app)

        editorScroll.swipeUp()
        let notes = app.textFields["transaction-notes-field"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("Regression note")
        XCTAssertTrue((notes.value as? String)?.contains("Regression note") == true)
        editorScroll.swipeDown()
        assertNoEditorKeyboard(in: app)

        let cleared = app.switches["Cleared"]
        XCTAssertTrue(cleared.waitForExistence(timeout: 5))
        cleared.tap()
        XCTAssertEqual(cleared.value as? String, "1")
        cleared.tap()
        XCTAssertEqual(cleared.value as? String, "0")

        let split = app.buttons["Split"]
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.tap()
        assertNoEditorKeyboard(in: app)
        let splitAmount = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transaction-split-amount-'")
        ).firstMatch
        XCTAssertTrue(splitAmount.waitForExistence(timeout: 5))
        splitAmount.tap()
        waitForAmountInput(in: app)
        dismissNumberPadPopover(in: app, editor: editor)
        let childPayee = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Payee'")).element(boundBy: 1)
        XCTAssertTrue(childPayee.waitForExistence(timeout: 5))
        childPayee.tap()
        let childPayeePicker = app.navigationBars["Payee"]
        XCTAssertTrue(childPayeePicker.waitForExistence(timeout: 5))
        let childSearch = app.textFields["Search or enter custom payee"]
        XCTAssertTrue(childSearch.waitForExistence(timeout: 5))
        childSearch.tap()
        childSearch.typeText("Daily Grind")
        let dailyGrind = app.buttons["Daily Grind"]
        XCTAssertTrue(dailyGrind.waitForExistence(timeout: 5))
        dailyGrind.tap()
        XCTAssertTrue(childPayeePicker.waitForNonExistence(timeout: 5))
        assertNoEditorKeyboard(in: app)

        captureScreenshot(named: requireWide ? "transaction-editor-ipad-picker-return" : "transaction-editor-iphone-picker-return")
        editor.buttons.firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        addTransaction.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        waitForAmountInput(in: app)
        app.typeText("7")
        XCTAssertTrue(formattedAmount(containing: "0.07", in: app).waitForExistence(timeout: 5))
    }

    private func waitForAmountInput(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 3) { return }
        let floatingNumberPad = app.popovers.containing(.key, identifier: "1").firstMatch
        XCTAssertTrue(floatingNumberPad.waitForExistence(timeout: 5))
    }

    private func assertNoEditorKeyboard(in app: XCUIApplication) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.popovers.containing(.key, identifier: "1").firstMatch.waitForNonExistence(timeout: 5))
    }

    private func captureScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    func testEditorUsesAvailableSheetHeight() {
        verifyEditorSheetLayout()
    }

    func testCalendarPopoverShowsFullWeek() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 10))
        addTransaction.tap()
        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        dismissNumberPadPopover(in: app, editor: editor)
        app.buttons["transaction-date-picker"].tap()

        let calendar = app.datePickers.firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(calendar.frame.width, 300)
        let days = calendar.buttons.matching(NSPredicate(format: "label MATCHES '.* [0-9]{1,2}$'"))
        let visibleDays = days.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertGreaterThanOrEqual(visibleDays.count, 28)
        XCTAssertTrue(visibleDays.allSatisfy { $0.frame.width >= 30 })
        XCTAssertTrue(visibleDays.allSatisfy { app.windows.firstMatch.frame.contains($0.frame) })
        captureScreenshot(named: "transaction-editor-full-calendar")
        visibleDays.first?.tap()
        assertNoEditorKeyboard(in: app)
    }

    private func verifyEditorSheetLayout() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 10))
        addTransaction.tap()
        let editorScroll = app.scrollViews["transaction-editor-scroll"]
        XCTAssertTrue(editorScroll.waitForExistence(timeout: 5))
        editorScroll.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Transaction editor portrait"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        if app.windows.firstMatch.frame.width > 700 {
            XCTAssertLessThanOrEqual(editorScroll.frame.width, 640)
            XCTAssertGreaterThan(editorScroll.frame.height, app.windows.firstMatch.frame.height * 0.75)
            XCTAssertTrue(editorScroll.frame.contains(app.buttons["transaction-save-button"].frame))

            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(editorScroll.frame.width, 640)
            XCTAssertGreaterThan(editorScroll.frame.height, app.windows.firstMatch.frame.height * 0.75)
            let landscape = XCTAttachment(screenshot: app.screenshot())
            landscape.name = "Transaction editor landscape"
            landscape.lifetime = .keepAlways
            add(landscape)
            editorScroll.swipeUp()
            XCTAssertTrue(app.buttons["transaction-save-button"].isHittable)
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testEditorLightAppearance() {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        let theme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 10))
        theme.tap()
        app.buttons["Actual Purple (light)"].tap()
        app.terminate()
        verifyEditorSheetLayout()
        app.terminate()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        XCTAssertTrue(theme.waitForExistence(timeout: 10))
        theme.tap()
        app.buttons["Actual Purple (dark)"].tap()
    }

    private func formattedAmount(containing amount: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", amount)).firstMatch
    }
}
