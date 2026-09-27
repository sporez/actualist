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
        if cancelSearch.exists && cancelSearch.isHittable { cancelSearch.tap() }
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
            "Read-only in Actualist",
            "The next occurrence is unavailable.",
        ] {
            scrollToVisible(
                app.staticTexts[expectedText].firstMatch,
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
        let privacy = launchDemo(screen: "settings/privacy", replaceDemo: true)
        setSampleValues(sampleValues, in: privacy)
        privacy.terminate()

        let appearance = launchDemo(screen: "settings/appearance")
        setTheme(theme, in: appearance)
        appearance.terminate()
    }

    private func restoreDefaults() {
        let privacy = launchDemo(screen: "settings/privacy")
        setSampleValues(false, in: privacy)
        privacy.terminate()

        let appearance = launchDemo(screen: "settings/appearance")
        setTheme("Actual Purple (dark)", in: appearance)
        appearance.terminate()
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

    private func launchBudget(dynamicType: String? = nil) -> XCUIApplication {
        launchDemo(screen: "budget", dynamicType: dynamicType)
    }

    private func launchDemo(
        screen: String,
        replaceDemo: Bool = false,
        dynamicType: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        if replaceDemo {
            app.launchArguments.append("-actualist-replace-demo-for-ui-testing")
        }
        if let dynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicType]
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        return app
    }

    private func requireCompact(_ app: XCUIApplication) throws {
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact window") }
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
