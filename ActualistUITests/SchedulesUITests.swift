import XCTest

@MainActor
final class SchedulesUITests: XCTestCase {
    private let fixtureScheduleName = "Annual Insurance"
    private let maskedScheduleName = "Sample Schedule 35"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompactDarkEntryDetailSearchAndRefresh() throws {
        XCUIDevice.shared.orientation = .portrait
        prepareDemo(theme: "Actual Purple (dark)", sampleValues: false)
        let app = launchBudget()
        defer {
            app.terminate()
            restoreDefaults()
        }
        try requireCompact(app)

        openSchedules(in: app)
        let row = scheduleRow(named: fixtureScheduleName, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        attachScreenshot(named: "schedules-compact-dark", app: app)

        try exerciseFixtureDetailAndBack(in: app, layout: "compact")
        exerciseSearchAndRefresh(for: fixtureScheduleName, in: app)
        closeSchedules(in: app)
    }

    func testCompactLightPrivacyAtAccessibilityXXXL() throws {
        XCUIDevice.shared.orientation = .portrait
        prepareDemo(theme: "Actual Purple (light)", sampleValues: true)
        let app = launchBudget(
            dynamicType: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        defer {
            app.terminate()
            restoreDefaults()
        }
        try requireCompact(app)

        openSchedules(in: app)
        assertMaskedFixture(in: app)
        XCTAssertTrue(scheduleRow(named: maskedScheduleName, in: app).isHittable)
        let search = app.searchFields["Search schedules"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.buttons["schedules-close"].isHittable)
        attachScreenshot(named: "schedules-compact-light-privacy-axxxl", app: app)

        exerciseSearchAndRefresh(for: maskedScheduleName, in: app)
        closeSchedules(in: app)
    }

    func testWideDarkEntryAndDetail() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        prepareDemo(theme: "Actual Purple (dark)", sampleValues: false)
        let app = launchBudget()
        defer {
            app.terminate()
            restoreDefaults()
        }
        try requireWide(app)

        openSchedules(in: app)
        XCTAssertTrue(scheduleRow(named: fixtureScheduleName, in: app).waitForExistence(timeout: 8))
        attachScreenshot(named: "schedules-wide-dark", app: app)

        try exerciseFixtureDetailAndBack(in: app, layout: "wide")
        closeSchedules(in: app)
    }

    func testWideLightPrivacySearchAndRefresh() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        prepareDemo(theme: "Actual Purple (light)", sampleValues: true)
        let app = launchBudget()
        defer {
            app.terminate()
            restoreDefaults()
        }
        try requireWide(app)

        openSchedules(in: app)
        assertMaskedFixture(in: app)
        attachScreenshot(named: "schedules-wide-light-privacy", app: app)

        exerciseSearchAndRefresh(for: maskedScheduleName, in: app)
        closeSchedules(in: app)
    }

    private func openSchedules(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actions = app.buttons["Budget Actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 15), file: file, line: line)
        XCTAssertTrue(actions.isHittable, file: file, line: line)
        actions.tap()

        let entry = app.buttons["budget-schedules-open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), file: file, line: line)
        entry.tap()

        let sheet = app.descendants(matching: .any)["schedules-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(app.navigationBars["Schedules"].waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertTrue(app.buttons["schedules-close"].waitForExistence(timeout: 5), file: file, line: line)
    }

    private func closeSchedules(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cancelSearch = app.buttons["Cancel"]
        let closeSearch = app.buttons["close"]
        if cancelSearch.exists && cancelSearch.isHittable {
            cancelSearch.tap()
        } else if closeSearch.exists && closeSearch.isHittable {
            closeSearch.tap()
        }
        let close = app.buttons["schedules-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), file: file, line: line)
        close.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["schedules-sheet"].waitForNonExistence(timeout: 8),
            file: file,
            line: line
        )
    }

    private func exerciseFixtureDetailAndBack(
        in app: XCUIApplication,
        layout: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let row = scheduleRow(named: fixtureScheduleName, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        row.tap()

        let detail = app.navigationBars["Schedule Details"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8), file: file, line: line)
        let detailList = try XCTUnwrap(
            app.collectionViews.allElementsBoundByIndex.first { $0.isHittable },
            "Schedule detail list must be reachable",
            file: file,
            line: line
        )
        attachScreenshot(named: "schedules-\(layout)-dark-detail-top", app: app)

        for expectedText in [
            fixtureScheduleName,
            "Date unavailable",
            "Every year",
            "Unavailable account",
            "No payee",
        ] {
            scrollToVisible(
                detailList.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", expectedText)).firstMatch,
                named: expectedText,
                in: detailList,
                file: file,
                line: line
            )
        }
        assertDenseTransactionRows(
            in: detailList,
            layout: layout,
            app: app,
            file: file,
            line: line
        )

        for expectedText in [
            "Read-only in Actualist",
            "The next occurrence is unavailable.",
        ] {
            scrollToVisible(
                detailList.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", expectedText)).firstMatch,
                named: expectedText,
                in: detailList,
                file: file,
                line: line
            )
        }
        attachScreenshot(named: "schedules-\(layout)-dark-detail-availability", app: app)

        let back = detail.buttons["Schedules"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), file: file, line: line)
        back.tap()
        XCTAssertTrue(app.navigationBars["Schedules"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(scheduleRow(named: fixtureScheduleName, in: app).waitForExistence(timeout: 5), file: file, line: line)
    }

    private func assertDenseTransactionRows(
        in detailList: XCUIElement,
        layout: String,
        app: XCUIApplication,
        file: StaticString,
        line: UInt
    ) {
        let account = detailRow(labeled: "Account, Unavailable account", in: detailList)
        let payee = detailRow(labeled: "Payee, No payee", in: detailList)
        let automaticPosting = detailRow(
            labeled: "Automatic posting, Disabled",
            in: detailList
        )
        for (name, row) in [
            ("Account", account),
            ("Payee", payee),
            ("Automatic posting", automaticPosting),
        ] {
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "Missing schedule detail row: \(name)",
                file: file,
                line: line
            )
        }

        // These fixture values are single-line at normal text size and the view
        // adds no custom row padding. Allow almost two native row heights while
        // rejecting the hundreds-of-points expansion this regression covers.
        let maximumNativeRowCenterGap: CGFloat = 80
        let accountToPayee = payee.frame.midY - account.frame.midY
        let payeeToAutomaticPosting = automaticPosting.frame.midY - payee.frame.midY
        XCTAssertGreaterThan(accountToPayee, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(
            accountToPayee,
            maximumNativeRowCenterGap,
            "Account and Payee rows must keep native List spacing",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(payeeToAutomaticPosting, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(
            payeeToAutomaticPosting,
            maximumNativeRowCenterGap,
            "Payee and Automatic posting rows must keep native List spacing",
            file: file,
            line: line
        )

        scrollToVisible(
            automaticPosting,
            named: "Automatic posting",
            in: detailList,
            file: file,
            line: line
        )
        attachScreenshot(
            named: "schedules-\(layout)-dark-detail-transaction-dense",
            app: app
        )
    }

    private func detailRow(labeled label: String, in detailList: XCUIElement) -> XCUIElement {
        detailList.staticTexts
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func exerciseSearchAndRefresh(
        for scheduleName: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let refresh = app.buttons["Refresh Schedules"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(refresh.isHittable, file: file, line: line)
        refresh.tap()
        XCTAssertTrue(waitForEnabled(refresh), file: file, line: line)
        XCTAssertTrue(scheduleRow(named: scheduleName, in: app).waitForExistence(timeout: 8), file: file, line: line)

        let search = app.searchFields["Search schedules"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), file: file, line: line)
        search.tap()
        search.typeText(scheduleName)
        XCTAssertTrue(scheduleRow(named: scheduleName, in: app).waitForExistence(timeout: 5), file: file, line: line)

        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        search.typeText("not-a-demo-schedule")
        XCTAssertTrue(app.staticTexts["No Matching Schedules"].waitForExistence(timeout: 5), file: file, line: line)
    }

    private func scrollToVisible(
        _ element: XCUIElement,
        named name: String,
        in scrollView: XCUIElement,
        file: StaticString,
        line: UInt
    ) {
        for _ in 0..<6 where !element.isHittable {
            scrollView.swipeUp()
        }
        XCTAssertTrue(element.exists, "Unreachable schedule detail: \(name)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "Schedule detail stayed offscreen: \(name)", file: file, line: line)
    }

    private func assertMaskedFixture(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.staticTexts["Schedule names, accounts, payees, and amounts use sample values."]
                .waitForExistence(timeout: 5),
            file: file,
            line: line
        )
        let masked = scheduleRow(named: maskedScheduleName, in: app)
        XCTAssertTrue(masked.waitForExistence(timeout: 8), file: file, line: line)
        XCTAssertFalse(masked.label.contains(fixtureScheduleName), file: file, line: line)
        XCTAssertFalse(masked.label.contains("1,200"), file: file, line: line)
        XCTAssertTrue(masked.label.contains("273.06"), file: file, line: line)
        XCTAssertFalse(scheduleRow(named: fixtureScheduleName, in: app).exists, file: file, line: line)
    }

    private func scheduleRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"),
                object: element
            )],
            timeout: 8
        ) == .completed
    }

    private func prepareDemo(theme: String, sampleValues: Bool) {
        let app = launchBudget(replaceDemo: true)
        openNativeSettings(in: app)
        openSettingsPage("Privacy & Notifications", in: app)
        setSampleValues(sampleValues, in: app)
        returnToSettingsDirectoryIfNeeded(from: "Privacy & Notifications", in: app)
        openSettingsPage("Appearance", in: app)
        setTheme(theme, in: app)
        app.terminate()
    }

    private func restoreDefaults() {
        let app = launchBudget()
        openNativeSettings(in: app)
        openSettingsPage("Privacy & Notifications", in: app)
        setSampleValues(false, in: app)
        returnToSettingsDirectoryIfNeeded(from: "Privacy & Notifications", in: app)
        openSettingsPage("Appearance", in: app)
        setTheme("Actual Purple (dark)", in: app)
        app.terminate()
    }

    private func openNativeSettings(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if isWide(app) {
            let sidebar = app.collectionViews["Sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 8), file: file, line: line)
            let settings = sidebar.cells.containing(.staticText, identifier: "Settings").firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5), file: file, line: line)
            XCTAssertTrue(settings.isHittable, file: file, line: line)
            settings.tap()
            XCTAssertTrue(
                app.navigationBars["Connection & Sync"].waitForExistence(timeout: 8),
                file: file,
                line: line
            )
        } else {
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), file: file, line: line)
            XCTAssertTrue(settings.isHittable, file: file, line: line)
            settings.tap()
            XCTAssertTrue(
                app.navigationBars["Settings"].waitForExistence(timeout: 8),
                file: file,
                line: line
            )
        }
    }

    private func openSettingsPage(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(row.isHittable, file: file, line: line)
        row.tap()
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: 8),
            file: file,
            line: line
        )
    }

    private func returnToSettingsDirectoryIfNeeded(
        from title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !isWide(app) else { return }
        let back = app.navigationBars[title].buttons["Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), file: file, line: line)
        back.tap()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5),
            file: file,
            line: line
        )
    }

    private func setSampleValues(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = app.switches["Use Sample Values"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let expectedValue = enabled ? "1" : "0"
        if toggle.value as? String != expectedValue {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func setTheme(_ themeName: String, in app: XCUIApplication) {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let theme = app.buttons[themeName]
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        theme.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", themeName),
            object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    private func launchBudget(
        replaceDemo: Bool = false,
        dynamicType: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        if replaceDemo {
            app.launchArguments.append("-actualist-replace-demo-for-ui-testing")
        }
        if let dynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicType]
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        if isWide(app) {
            XCTAssertTrue(app.collectionViews["Sidebar"].waitForExistence(timeout: 8))
        } else {
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        }
        return app
    }

    private func requireCompact(_ app: XCUIApplication) throws {
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact window") }
    }

    private func isWide(_ app: XCUIApplication) -> Bool {
        app.frame.width >= 792
    }

    private func requireWide(_ app: XCUIApplication) throws {
        guard app.frame.width >= 792 else { throw XCTSkip("Requires a wide iPad window") }
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
