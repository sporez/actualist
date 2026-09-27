import XCTest

@MainActor
final class ReportExplorerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAdaptiveReportEntryFiltersResetAndContributorDrilldownInDarkTheme() throws {
        prepareDemo(theme: "Actual Purple (dark)", sampleValues: false)
        let app = launchDemo(screen: "budget")

        try openReportsFromNativeNavigation(in: app)
        try openReportCard(named: "This Month", in: app)
        XCTAssertTrue(app.navigationBars["This Month"].waitForExistence(timeout: 8))

        let rangeMenu = app.buttons["Report date range"]
        XCTAssertTrue(rangeMenu.waitForExistence(timeout: 5))
        rangeMenu.tap()
        for title in ["Month to Date", "Last 3 Months", "Last 6 Months", "Year to Date", "Custom Range…"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3))
        }
        app.buttons["Last 3 Months"].tap()
        XCTAssertTrue(app.staticTexts["Last 3 Months"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["report-drilldown-button"].waitForExistence(timeout: 8))

        openFilters(in: app)
        assertSwitch("report-filter-off-budget", equals: false, in: app)
        assertSwitch("report-filter-hidden-categories", equals: true, in: app)
        assertSwitch("report-filter-uncategorized", equals: true, in: app)

        let noneButtons = try filterNoneButtons(in: app)
        noneButtons[0].tap()
        scrollUntilHittable(noneButtons[1], in: filterScroller(in: app), direction: .up)
        noneButtons[1].tap()

        let uncategorized = app.switches["report-filter-uncategorized"]
        scrollUntilHittable(uncategorized, in: filterScroller(in: app), direction: .up)
        assertSwitch("report-filter-uncategorized", equals: false, in: app)
        uncategorized.tap()
        assertSwitch("report-filter-uncategorized", equals: true, in: app)
        app.buttons["report-filter-apply"].tap()

        XCTAssertTrue(app.navigationBars["Report Filters"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Activity in This Range"].waitForExistence(timeout: 8))

        openFilters(in: app)
        assertSwitch("report-filter-account-checking", equals: false, in: app)
        assertSwitch("report-filter-account-savings", equals: false, in: app)
        assertSwitch("report-filter-account-credit", equals: false, in: app)
        assertSwitch("report-filter-uncategorized", equals: true, in: app)
        revealCategoryGroup("Essentials", in: app)
        assertSwitch("report-filter-category-rent", equals: false, in: app)
        attachScreenshot(named: "reports-filter-empty-dark-\(layoutName(in: app))", app: app)

        let reset = app.buttons["report-filter-reset"]
        scrollUntilHittable(reset, in: filterScroller(in: app), direction: .up)
        reset.tap()
        app.buttons["report-filter-apply"].tap()

        XCTAssertTrue(app.navigationBars["Report Filters"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["report-drilldown-button"].waitForExistence(timeout: 8))
        app.buttons["report-drilldown-button"].tap()

        XCTAssertTrue(app.navigationBars["This Month Transactions"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["report-drilldown-view"].waitForExistence(timeout: 5))
        let count = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* contributing transactions?")
        ).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(elements(in: app, identifierPrefix: "report-drilldown-row-").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(elements(in: app, identifierPrefix: "report-drilldown-contributor-").firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(named: "reports-drilldown-dark-\(layoutName(in: app))", app: app)
    }

    func testAdaptiveAverageAndNetWorthStayPrivateAtAccessibilitySizeInLightTheme() throws {
        prepareDemo(theme: "Actual Purple (light)", sampleValues: true)
        let app = launchDemo(
            screen: "budget",
            dynamicType: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        defer {
            app.terminate()
            restoreDefaults()
        }
        try openReportsFromNativeNavigation(in: app)
        try openReportCard(named: "3-Month Average", in: app)
        XCTAssertTrue(app.navigationBars["3-Month Average"].waitForExistence(timeout: 8))

        XCTAssertFalse(app.buttons["Report date range"].exists)
        let comparisonMonth = app.buttons["Comparison month"]
        XCTAssertTrue(comparisonMonth.waitForExistence(timeout: 5))
        let initialMonth = comparisonMonthLabel(in: app)
        comparisonMonth.tap()
        XCTAssertTrue(app.buttons["Previous Month"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Next Month"].exists)
        app.buttons["Previous Month"].tap()
        let selectedMonth = waitForComparisonMonthChange(from: initialMonth, in: app)
        XCTAssertNotEqual(selectedMonth, initialMonth)
        XCTAssertTrue(isSingleMonthRangeVisible(for: selectedMonth, in: app))

        openFilters(in: app)
        let checking = app.switches["report-filter-account-checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        XCTAssertFalse(checking.label.contains("Everyday Checking"))
        XCTAssertFalse(app.staticTexts["Everyday Checking"].exists)
        XCTAssertTrue(app.switches["report-filter-uncategorized"].exists)
        app.navigationBars["Report Filters"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Report Filters"].waitForNonExistence(timeout: 5))
        attachScreenshot(named: "reports-average-light-privacy-ax-\(layoutName(in: app))", app: app)

        returnToReports(from: "3-Month Average", in: app)
        try openReportCard(named: "Net Worth", in: app)
        XCTAssertTrue(app.navigationBars["Net Worth"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["report-drilldown-button"].waitForExistence(timeout: 1))

        openFilters(in: app)
        XCTAssertTrue(app.switches["report-filter-account-checking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["report-filter-off-budget"].exists)
        XCTAssertFalse(app.switches["report-filter-uncategorized"].exists)
        XCTAssertEqual(elements(in: app, identifierPrefix: "report-filter-category-").count, 0)
        attachScreenshot(named: "reports-net-worth-filter-light-privacy-ax-\(layoutName(in: app))", app: app)
    }

    private enum ScrollDirection {
        case up
        case down
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

    private func openReportsFromNativeNavigation(in app: XCUIApplication) throws {
        let tabBar = app.tabBars.firstMatch
        let sidebar = app.collectionViews["Sidebar"]
        let shellReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabBar.exists || sidebar.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shellReady], timeout: 15), .completed)

        if tabBar.exists {
            let reports = tabBar.buttons["Reports"]
            XCTAssertTrue(reports.waitForExistence(timeout: 5))
            reports.tap()
        } else {
            let reports = sidebar.cells.containing(.staticText, identifier: "Reports").firstMatch
            XCTAssertTrue(reports.waitForExistence(timeout: 5))
            reports.tap()
        }
        XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 10))
        XCTAssertTrue(reportCard(named: "Net Worth", in: app).waitForExistence(timeout: 8))
    }

    private func openReportCard(named title: String, in app: XCUIApplication) throws {
        let card = reportCard(named: title, in: app)
        let scroller = app.scrollViews.firstMatch
        for _ in 0..<10 where !card.isHittable {
            if card.exists, card.frame.minY < scroller.frame.minY {
                scroller.swipeDown()
            } else {
                scroller.swipeUp()
            }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.isHittable)
        card.tap()
    }

    private func reportCard(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.containing(.staticText, identifier: title).firstMatch
    }

    private func returnToReports(from title: String, in app: XCUIApplication) {
        let back = app.navigationBars[title].buttons["Reports"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 8))
    }

    private func openFilters(in app: XCUIApplication) {
        let filters = app.buttons["report-filter-button"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertTrue(filters.isHittable)
        filters.tap()
        XCTAssertTrue(app.navigationBars["Report Filters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["report-filter-sheet"].exists)
    }

    private func filterNoneButtons(in app: XCUIApplication) throws -> [XCUIElement] {
        let buttons = app.buttons.matching(NSPredicate(format: "label == 'None'"))
        let bothLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in buttons.count == 2 },
            object: nil
        )
        if XCTWaiter.wait(for: [bothLoaded], timeout: 3) != .completed {
            let scroller = filterScroller(in: app)
            for _ in 0..<5 where buttons.count < 2 { scroller.swipeUp() }
        }
        XCTAssertEqual(buttons.count, 2)
        return buttons.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func revealCategoryGroup(_ title: String, in app: XCUIApplication) {
        let category = app.switches["report-filter-category-rent"]
        guard !category.exists else { return }
        let group = app.buttons[title]
        scrollUntilHittable(group, in: filterScroller(in: app), direction: .up)
        XCTAssertTrue(group.isHittable)
        group.tap()
        XCTAssertTrue(category.waitForExistence(timeout: 5))
    }

    private func comparisonMonthLabel(in app: XCUIApplication) -> String {
        let monthPattern = NSPredicate(format: "label MATCHES %@", "[A-Za-z]+ [0-9]{4}")
        let month = app.staticTexts.matching(monthPattern).firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        return month.label
    }

    private func isSingleMonthRangeVisible(for monthTitle: String, in app: XCUIApplication) -> Bool {
        let parts = monthTitle.split(separator: " ")
        guard parts.count == 2 else { return false }
        let monthPrefix = String(parts[0].prefix(3))
        let year = String(parts[1])
        let range = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ AND label ENDSWITH %@ AND label CONTAINS '–'",
                monthPrefix,
                year
            )
        ).firstMatch
        return range.waitForExistence(timeout: 5)
    }

    private func waitForComparisonMonthChange(
        from initialMonth: String,
        in app: XCUIApplication
    ) -> String {
        let monthPattern = NSPredicate(format: "label MATCHES %@", "[A-Za-z]+ [0-9]{4}")
        let month = app.staticTexts.matching(monthPattern).firstMatch
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", initialMonth),
            object: month
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        return month.label
    }

    private func filterScroller(in app: XCUIApplication) -> XCUIElement {
        let form = app.collectionViews.firstMatch
        return form.exists ? form : app.scrollViews.firstMatch
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        in scroller: XCUIElement,
        direction: ScrollDirection
    ) {
        for _ in 0..<8 where !element.isHittable {
            switch direction {
            case .up:
                scroller.swipeUp()
            case .down:
                scroller.swipeDown()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        XCTAssertTrue(element.isHittable)
    }

    private func assertSwitch(_ identifier: String, equals enabled: Bool, in app: XCUIApplication) {
        let toggle = app.switches[identifier]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let expected = enabled ? "1" : "0"
        let value = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed)
    }

    private func setSampleValues(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = app.switches["Use Sample Values"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let expected = enabled ? "1" : "0"
        if toggle.value as? String != expected {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func setTheme(_ themeName: String, in app: XCUIApplication) {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'"))
            .firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        if !picker.label.contains(themeName) {
            picker.tap()
            let theme = app.buttons[themeName]
            XCTAssertTrue(theme.waitForExistence(timeout: 5))
            theme.tap()
        }
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", themeName),
            object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
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

    private func elements(
        in app: XCUIApplication,
        identifierPrefix: String
    ) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        )
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
