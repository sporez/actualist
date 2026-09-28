import XCTest

@MainActor
final class ReportExplorerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAdaptiveReportEntryFiltersResetAndContributorDrilldownInDarkTheme() throws {
        prepareDemo(theme: "Actual Purple (dark)", sampleValues: false)
        let app = launchDemo(screen: "budget")
        defer {
            app.terminate()
            restoreDefaults()
        }

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

        revealReportElement(
            app.descendants(matching: .any)["report-explorer-chart"].firstMatch,
            in: app, navigationTitle: "This Month"
        )
        attachScreenshot(named: "reports-chart-dark-\(layoutName(in: app))", app: app)
        openFilters(in: app)
        assertSwitch("report-filter-off-budget", equals: false, in: app)
        assertSwitch("report-filter-hidden-categories", equals: true, in: app)
        assertSwitch("report-filter-uncategorized", equals: true, in: app)

        let noneButtons = try filterNoneButtons(in: app)
        scrollUntilHittable(noneButtons[0], in: filterScroller(in: app), direction: .down)
        noneButtons[0].tap()
        scrollUntilHittable(noneButtons[1], in: filterScroller(in: app), direction: .up)
        noneButtons[1].tap()

        let uncategorized = app.switches["report-filter-uncategorized"]
        scrollUntilHittable(uncategorized, in: filterScroller(in: app), direction: .up)
        assertSwitch("report-filter-uncategorized", equals: false, in: app)
        uncategorized.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
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
        revealReportElement(
            app.buttons["report-drilldown-button"], in: app, navigationTitle: "This Month"
        )
        app.buttons["report-drilldown-button"].tap()

        XCTAssertTrue(app.navigationBars["This Month Transactions"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["report-drilldown-view"].waitForExistence(timeout: 5))
        let count = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* contributing transactions?")
        ).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(elements(in: app, identifierPrefix: "report-drilldown-row-").firstMatch.waitForExistence(timeout: 5))
        let countedRow = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "report-drilldown-row-", "Counted"
        )).firstMatch
        XCTAssertTrue(countedRow.waitForExistence(timeout: 5))
        attachScreenshot(named: "reports-drilldown-dark-\(layoutName(in: app))", app: app)

        app.navigationBars["This Month Transactions"].buttons["This Month"].tap()
        XCTAssertTrue(app.navigationBars["This Month"].waitForExistence(timeout: 5))
        returnToReports(from: "This Month", in: app)
        try openReportCard(named: "Budget Overview", in: app)
        XCTAssertTrue(app.navigationBars["Budget Overview"].waitForExistence(timeout: 5))
        app.buttons["Report date range"].tap()
        app.buttons["Last 3 Months"].tap()
        XCTAssertTrue(app.staticTexts["Last 3 Months"].waitForExistence(timeout: 5))
        revealReportElement(
            app.descendants(matching: .any)["report-explorer-chart"].firstMatch,
            in: app, navigationTitle: "Budget Overview"
        )
        attachScreenshot(named: "reports-budget-chart-dark-\(layoutName(in: app))", app: app)
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
        let expectedRange = try XCTUnwrap(completedMonthRangeTitle(for: selectedMonth))
        XCTAssertTrue(app.staticTexts[expectedRange].waitForExistence(timeout: 8))

        openFilters(in: app)
        let checking = assertSwitch("report-filter-account-checking", equals: true, in: app)
        XCTAssertFalse(checking.label.contains("Everyday Checking"))
        XCTAssertFalse(app.staticTexts["Everyday Checking"].exists)
        assertSwitch("report-filter-uncategorized", equals: true, in: app)
        app.navigationBars["Report Filters"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Report Filters"].waitForNonExistence(timeout: 5))
        attachScreenshot(named: "reports-average-light-privacy-ax-\(layoutName(in: app))", app: app)

        let drilldown = app.buttons["report-drilldown-button"]
        revealReportElement(drilldown, in: app, navigationTitle: "3-Month Average")
        XCTAssertTrue(drilldown.isHittable)
        attachScreenshot(named: "reports-drilldown-button-light-privacy-ax-\(layoutName(in: app))", app: app)

        revealReportElement(
            app.descendants(matching: .any)["report-explorer-chart"].firstMatch,
            in: app, navigationTitle: "3-Month Average"
        )
        attachScreenshot(named: "reports-chart-light-privacy-ax-\(layoutName(in: app))", app: app)

        returnToReports(from: "3-Month Average", in: app)
        try openReportCard(named: "Net Worth", in: app)
        XCTAssertTrue(app.navigationBars["Net Worth"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["report-drilldown-button"].waitForExistence(timeout: 1))

        openFilters(in: app)
        assertSwitch("report-filter-account-checking", equals: true, in: app)
        assertSwitch(
            "report-filter-off-budget",
            equals: false,
            fallbackDirection: .down,
            in: app
        )
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
        let label = card.staticTexts[title].firstMatch
        let scroller = app.scrollViews.firstMatch
        let contentTop = app.navigationBars["Reports"].frame.maxY
        let contentBottom = app.tabBars.firstMatch.exists
            ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
        for _ in 0..<10 {
            if label.exists, label.isHittable,
               label.frame.minY >= contentTop,
               label.frame.maxY <= contentBottom { break }
            dragTowardVisibleCenter(
                label, in: scroller,
                contentTop: contentTop, contentBottom: contentBottom
            )
        }
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        XCTAssertTrue(label.isHittable)
        XCTAssertGreaterThanOrEqual(label.frame.minY, contentTop)
        XCTAssertLessThanOrEqual(label.frame.maxY, contentBottom)
        label.tap()
    }

    private func reportCard(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func dragTowardVisibleCenter(
        _ element: XCUIElement,
        in scroller: XCUIElement,
        contentTop: CGFloat,
        contentBottom: CGFloat
    ) {
        let midpoint = (contentTop + contentBottom) / 2
        let maximumDrag = (contentBottom - contentTop) * 0.45
        let distance = element.exists
            ? max(-maximumDrag, min(maximumDrag, midpoint - element.frame.midY))
            : -maximumDrag
        let origin = scroller.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(
            dx: scroller.frame.width * 0.5,
            dy: midpoint - scroller.frame.minY
        ))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(
            CGVector(dx: 0, dy: distance)
        ))
    }

    private func returnToReports(from title: String, in app: XCUIApplication) {
        let back = app.navigationBars[title].buttons["Reports"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 8))
    }

    private func revealReportElement(
        _ element: XCUIElement, in app: XCUIApplication, navigationTitle: String
    ) {
        let contentTop = app.navigationBars[navigationTitle].frame.maxY
        let contentBottom = app.tabBars.firstMatch.exists
            ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
        for _ in 0..<6 {
            if element.exists, element.frame.minY >= contentTop,
               element.frame.maxY <= contentBottom { break }
            dragTowardVisibleCenter(
                element, in: app.scrollViews.firstMatch,
                contentTop: contentTop, contentBottom: contentBottom
            )
        }
        XCTAssertTrue(element.exists)
        XCTAssertGreaterThanOrEqual(element.frame.minY, contentTop)
        XCTAssertLessThanOrEqual(element.frame.maxY, contentBottom)
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
        return buttons.allElementsBoundByIndex
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

    private func completedMonthRangeTitle(for monthTitle: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.locale = .current
        monthFormatter.dateFormat = "MMMM yyyy"
        guard let start = monthFormatter.date(from: monthTitle),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: start),
              let end = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
            return nil
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = .current
        dayFormatter.dateFormat = "MMM d, yyyy"
        return "\(dayFormatter.string(from: start)) – \(dayFormatter.string(from: end))"
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
        let sheet = app.descendants(matching: .any)["report-filter-sheet"]
        if let form = sheet.descendants(matching: .collectionView)
            .allElementsBoundByIndex.first(where: { $0.isHittable }) {
            return form
        }
        let scroller = sheet.descendants(matching: .scrollView).firstMatch
        XCTAssertTrue(scroller.isHittable)
        return scroller
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

    @discardableResult
    private func assertSwitch(
        _ identifier: String,
        equals enabled: Bool,
        fallbackDirection: ScrollDirection = .up,
        in app: XCUIApplication
    ) -> XCUIElement {
        let toggle = app.switches[identifier]
        let scroller = filterScroller(in: app)
        for _ in 0..<8 where !toggle.isHittable {
            if toggle.exists {
                if toggle.frame.minY < scroller.frame.minY {
                    scroller.swipeDown()
                } else {
                    scroller.swipeUp()
                }
            } else {
                switch fallbackDirection {
                case .up:
                    scroller.swipeUp()
                case .down:
                    scroller.swipeDown()
                }
            }
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertTrue(toggle.isHittable)
        let expected = enabled ? "1" : "0"
        let value = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed)
        return toggle
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
