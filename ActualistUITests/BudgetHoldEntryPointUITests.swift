import XCTest

@MainActor
final class BudgetHoldEntryPointUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCompactHoldPartialAllAndReleaseCancellation() throws {
        XCUIDevice.shared.orientation = .portrait
        setTheme("Actual Purple (dark)")
        let app = launchDemo(replaceDemo: true)
        try requireCompact(app)

        openCompactHold(in: app)
        let sheet = app.descendants(matching: .any)["budget-hold-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let initialAvailable = app.staticTexts["budget-hold-current-available"].label
        let initialHeld = app.staticTexts["budget-hold-current-held"].label
        let resultAvailable = app.staticTexts["budget-hold-result-available"]
        XCTAssertTrue(resultAvailable.waitForExistence(timeout: 5))
        let allResult = resultAvailable.label

        replaceAmount(with: "1", in: app)
        let partialResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", allResult),
            object: resultAvailable
        )
        XCTAssertEqual(XCTWaiter.wait(for: [partialResult], timeout: 5), .completed)
        XCTAssertNotEqual(resultAvailable.label, initialAvailable)
        let confirm = app.buttons["budget-hold-confirm"]
        XCTAssertTrue(waitForEnabled(confirm))
        confirm.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        openCompactHold(in: app)
        XCTAssertNotEqual(app.staticTexts["budget-hold-current-available"].label, initialAvailable)
        XCTAssertNotEqual(app.staticTexts["budget-hold-current-held"].label, initialHeld)
        capture("budget-hold-partial-dark", app)

        let release = app.buttons["budget-hold-release"]
        XCTAssertTrue(release.isEnabled)
        release.tap()
        let releaseConfirm = app.alerts.buttons.matching(identifier: "budget-hold-release-confirm").firstMatch
        XCTAssertTrue(releaseConfirm.waitForExistence(timeout: 5))
        capture("budget-hold-release-confirmation-dark", app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(releaseConfirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sheet.exists)
        XCTAssertTrue(release.isEnabled)

        release.tap()
        XCTAssertTrue(releaseConfirm.waitForExistence(timeout: 5))
        releaseConfirm.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        openCompactHold(in: app)
        let availableBeforeAll = app.staticTexts["budget-hold-current-available"].label
        app.buttons["budget-hold-use-all"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", availableBeforeAll), object: resultAvailable
        )], timeout: 5), .completed)
        XCTAssertTrue(waitForEnabled(confirm))
        confirm.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        // A full hold removes the zero To Budget banner, so this re-entry also
        // exercises the Budget Actions fallback.
        XCTAssertTrue(app.buttons["budget-hold-open"].waitForNonExistence(timeout: 5))
        openCompactHold(in: app)
        XCTAssertNotEqual(app.staticTexts["budget-hold-current-held"].label, initialHeld)
        XCTAssertNotEqual(app.staticTexts["budget-hold-current-available"].label, initialAvailable)
        capture("budget-hold-all-dark", app)

        app.buttons["budget-hold-release"].tap()
        XCTAssertTrue(releaseConfirm.waitForExistence(timeout: 5))
        releaseConfirm.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        app.terminate()
        setTheme("Actual Purple (light)")
        let light = launchDemo()
        defer {
            light.terminate()
            setTheme("Actual Purple (dark)")
        }
        openCompactHold(in: light)
        capture("budget-hold-review-light", light)
        light.buttons["budget-hold-close"].tap()
    }

    func testCompactFollowingMonthEntryInLightTheme() throws {
        XCUIDevice.shared.orientation = .portrait
        setTheme("Actual Purple (light)")
        let app = launchDemo(replaceDemo: true)
        defer {
            app.terminate()
            setTheme("Actual Purple (dark)")
        }
        try requireCompact(app)

        let calendar = Calendar(identifier: .gregorian)
        let followingDate = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: Date()))
        let followingTitle = Self.monthTitle(for: followingDate)
        let monthPicker = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", String(calendar.component(.year, from: Date())))
        ).firstMatch
        XCTAssertTrue(monthPicker.waitForExistence(timeout: 15))
        monthPicker.tap()
        app.buttons[Self.monthSymbol(for: followingDate)].tap()
        XCTAssertTrue(app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", followingTitle)
        ).firstMatch.waitForExistence(timeout: 10))

        openCompactHold(in: app)
        let destination = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: followingDate))
        XCTAssertEqual(app.staticTexts["budget-hold-month"].label, "\(followingTitle) → \(Self.monthTitle(for: destination))")
        XCTAssertTrue(app.descendants(matching: .any)["budget-hold-sheet"].exists)
        capture("budget-hold-following-month-light", app)
        app.buttons["budget-hold-close"].tap()
    }

    func testWideEntryCapturesTheTappedMonth() throws {
        setTheme("Actual Purple (dark)")
        let app = launchDemo(replaceDemo: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        try requireWide(app)
        XCTAssertTrue(app.scrollViews["budget-grid"].waitForExistence(timeout: 15))
        // Make room for both columns even when the simulator keeps a portrait window.
        let hideSidebar = app.buttons["Hide Sidebar"]
        if hideSidebar.exists { hideSidebar.tap() }
        app.buttons["Budget Actions"].tap()
        let monthCount = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Months Shown'")).firstMatch
        XCTAssertTrue(monthCount.waitForExistence(timeout: 3))
        monthCount.tap()
        app.buttons["2"].tap()

        let entryQuery = app.buttons.matching(
            NSPredicate(format: "label CONTAINS ', To Budget, '")
        )
        XCTAssertTrue(entryQuery.element(boundBy: 1).waitForExistence(timeout: 10))
        let entries = entryQuery.allElementsBoundByIndex
        XCTAssertGreaterThan(entries.count, 1)
        let entry = try XCTUnwrap(entries.last)
        let entryLabel = entry.label
        let monthTitle = String(try XCTUnwrap(entryLabel.split(separator: ",").first))
        entry.tap()

        XCTAssertTrue(app.descendants(matching: .any)["budget-hold-sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["budget-hold-current-available"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["budget-hold-month"].label.hasPrefix(monthTitle + " → "))
        XCTAssertTrue(entryLabel.contains(app.staticTexts["budget-hold-current-available"].label))
        assertReadableReview(in: app)
        capture("budget-hold-wide-captured-month", app)
        app.buttons["budget-hold-close"].tap()
        app.terminate()
        setTheme("Actual Purple (light)")
        let light = launchDemo()
        XCUIDevice.shared.orientation = .landscapeLeft
        let lightSidebar = light.buttons["Hide Sidebar"]
        if lightSidebar.exists { lightSidebar.tap() }
        defer {
            light.terminate()
            setTheme("Actual Purple (dark)")
        }
        let lightEntry = light.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", monthTitle + ", To Budget, ")
        ).firstMatch
        XCTAssertTrue(lightEntry.waitForExistence(timeout: 15))
        lightEntry.tap()
        XCTAssertTrue(light.staticTexts["budget-hold-current-available"].waitForExistence(timeout: 5))
        assertReadableReview(in: light)
        capture("budget-hold-wide-light", light)
        light.buttons["budget-hold-close"].tap()
    }

    private func openCompactHold(in app: XCUIApplication) {
        let entry = app.buttons["budget-hold-open"]
        if !entry.waitForExistence(timeout: 2) {
            app.buttons["Budget Actions"].tap()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-hold-sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["budget-hold-current-available"].waitForExistence(timeout: 5))
        assertReadableReview(in: app)
    }

    private func assertReadableReview(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let review = app.scrollViews["budget-hold-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), file: file, line: line)
        let bounds = review.frame
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(bounds.width, min(440, window.width - 40), file: file, line: line)
        XCTAssertLessThanOrEqual(bounds.width, 640, file: file, line: line)
        XCTAssertTrue(window.contains(bounds), "Review must fit the window", file: file, line: line)
        for identifier in ["budget-hold-current-available", "budget-hold-current-held", "budget-hold-result-available", "budget-hold-result-held"] {
            let amount = app.staticTexts[identifier]
            XCTAssertTrue(amount.isHittable, "\(identifier) must be visible", file: file, line: line)
            XCTAssertTrue(bounds.contains(amount.frame), "\(identifier) must fit inside the review", file: file, line: line)
        }
        let confirm = app.buttons["budget-hold-confirm"]
        XCTAssertGreaterThanOrEqual(confirm.frame.width, bounds.width / 2 - 40, file: file, line: line)
        XCTAssertTrue(window.contains(confirm.frame), "Hold action must be visible without scrolling", file: file, line: line)
    }

    private func replaceAmount(with text: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any)["budget-hold-amount"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        app.typeText(text)
        let done = app.buttons["keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)],
            timeout: 5
        ) == .completed
    }

    private func setTheme(_ name: String) {
        let settings = launchDemo(screen: "settings/appearance")
        let picker = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        settings.buttons[name].tap()
        let assigned = settings.switches["Show Total Assigned"]
        if assigned.waitForExistence(timeout: 3), assigned.value as? String == "1" { assigned.tap() }
        settings.terminate()
    }

    private func launchDemo(screen: String = "budget", replaceDemo: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        if replaceDemo { app.launchArguments.append("-actualist-replace-demo-for-ui-testing") }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func requireCompact(_ app: XCUIApplication) throws {
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact window") }
    }

    private func requireWide(_ app: XCUIApplication) throws {
        guard app.frame.width >= 792 else { throw XCTSkip("Requires a wide iPad window") }
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private static func monthSymbol(for date: Date) -> String {
        let calendar = Calendar.current
        return calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1]
    }
}
