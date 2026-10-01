import XCTest

@MainActor
final class TransactionStructuredFilterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSpendingApplyClearPreservesStatusAndSearch() throws {
        let app = launch(screen: "spending")
        selectStatus("Cleared", in: app)
        app.buttons["Search Transactions"].tap()
        let search = app.textFields["Search Transactions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("market")

        openMoreFilters(in: app)
        app.switches["transaction-filter-date-enabled"].tap()
        for field in ["account", "payee", "category"] {
            let selectedTitle = selectFirstOption(field: field, in: app)
            let summary = app.buttons["transaction-filter-select-\(field)"]
            XCTAssertTrue(summary.label.contains(selectedTitle), "Selection summary omitted \(selectedTitle)")
        }
        XCTAssertTrue(app.buttons["transaction-filter-apply"].isHittable)
        screenshot("structured-filter-spending-dark-compact", app: app)
        app.buttons["transaction-filter-apply"].tap()

        let structured = app.buttons["transaction-filter-clear-structured"]
        XCTAssertTrue(structured.waitForExistence(timeout: 5))
        XCTAssertTrue(structured.label.contains("4"))
        XCTAssertTrue(app.buttons["Clear Cleared Filter"].exists)
        XCTAssertEqual(search.value as? String, "market")
        let structuredLabel = structured.staticTexts["More Filters: 4"]
        XCTAssertTrue(structuredLabel.exists)
        XCTAssertTrue(structuredLabel.isHittable)
        structuredLabel.tap()
        XCTAssertTrue(structured.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Clear Cleared Filter"].exists)
        XCTAssertEqual(search.value as? String, "market")
    }

    func testCancelPreservesOuterFiltersAndAccountActionsOpensSelection() throws {
        let spending = launch(screen: "spending")
        selectStatus("Uncleared", in: spending)
        spending.buttons["Search Transactions"].tap()
        let search = spending.textFields["Search Transactions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("market")
        openMoreFilters(in: spending)
        spending.switches["transaction-filter-date-enabled"].tap()
        spending.buttons["transaction-filter-cancel"].tap()
        XCTAssertFalse(spending.buttons["transaction-filter-clear-structured"].exists)
        XCTAssertTrue(spending.buttons["Clear Uncleared Filter"].exists)
        XCTAssertEqual(search.value as? String, "market")

        let accounts = launch(screen: "accounts")
        openCheckingAccount(in: accounts)
        XCTAssertTrue(accounts.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))
        accounts.buttons["Account Actions"].tap()
        accounts.buttons["Filter Transactions"].tap()
        let more = accounts.buttons["transaction-more-filters"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(accounts.navigationBars["Transaction Filters"].waitForExistence(timeout: 5))
        let accountSelection = accounts.buttons["transaction-filter-select-account"]
        XCTAssertTrue(accountSelection.waitForExistence(timeout: 5))
        XCTAssertTrue(accountSelection.isHittable)
        accounts.buttons["transaction-filter-cancel"].tap()
    }

    func testOrConditionAppliesAndRemainsSelectedUntilClear() throws {
        let app = launch(screen: "spending")
        openMoreFilters(in: app)
        _ = selectFirstOption(field: "category", in: app)
        let join = app.segmentedControls["transaction-filter-join"]
        XCTAssertTrue(join.waitForExistence(timeout: 5))
        join.buttons["Any (OR)"].tap()
        XCTAssertTrue(join.buttons["Any (OR)"].isSelected)
        screenshot("structured-filter-spending-dark-wide-review", app: app)
        app.buttons["transaction-filter-apply"].tap()

        let clear = app.buttons["transaction-filter-clear-structured"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        app.buttons["Transaction Actions"].tap()
        app.buttons["Filter Transactions"].tap()
        app.buttons["transaction-more-filters"].tap()
        let reopenedJoin = app.segmentedControls["transaction-filter-join"]
        XCTAssertTrue(reopenedJoin.waitForExistence(timeout: 5))
        XCTAssertTrue(reopenedJoin.buttons["Any (OR)"].isSelected)
        app.switches["transaction-filter-date-enabled"].tap()
        app.buttons["transaction-filter-cancel"].tap()
        XCTAssertTrue(clear.exists)
        XCTAssertTrue(clear.label.contains("1"))

        app.buttons["Transaction Actions"].tap()
        app.buttons["Filter Transactions"].tap()
        app.buttons["transaction-more-filters"].tap()
        XCTAssertTrue(app.segmentedControls["transaction-filter-join"].buttons["Any (OR)"].isSelected)
        XCTAssertEqual(app.switches["transaction-filter-date-enabled"].value as? String, "0")
        app.buttons["transaction-filter-cancel"].tap()
        let clearLabel = clear.staticTexts["More Filters: 1"]
        XCTAssertTrue(clearLabel.exists)
        XCTAssertTrue(clearLabel.isHittable)
        clearLabel.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 2))
    }

    func testWideFilterReviewScreenshot() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(screen: "spending")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
            object: app
        )
        let orientationResult = XCTWaiter.wait(for: [landscapeExpectation], timeout: 5)
        XCTAssertEqual(orientationResult, .completed, "Spending must finish rotating to landscape")
        guard orientationResult == .completed, app.frame.width > app.frame.height else { return }

        openMoreFilters(in: app)
        XCTAssertTrue(app.navigationBars["Transaction Filters"].exists)
        XCTAssertTrue(app.buttons["transaction-filter-select-category"].exists)
        screenshot("structured-filter-spending-dark-wide", app: app)
        let screenAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenAttachment.name = "structured-filter-spending-dark-wide-full-screen"
        screenAttachment.lifetime = .keepAlways
        add(screenAttachment)
        _ = selectFirstOption(field: "payee", in: app)
        app.buttons["transaction-filter-cancel"].tap()
    }

    func testLightAppearanceFilterScreenshotRestoresDarkTheme() throws {
        defer { restoreDarkAppearance() }
        let settings = launch(screen: "budget", replaceDemo: true)
        openNativeAppearance(in: settings)
        let theme = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        theme.tap()
        let lightTheme = settings.buttons["Actual Purple (light)"]
        XCTAssertTrue(lightTheme.waitForExistence(timeout: 3))
        lightTheme.tap()
        settings.terminate()

        let app = launch(screen: "spending", replaceDemo: false)
        openMoreFilters(in: app)
        app.switches["transaction-filter-date-enabled"].tap()
        screenshot("structured-filter-spending-light-compact", app: app)
        _ = selectFirstOption(field: "category", in: app)
        app.buttons["transaction-filter-cancel"].tap()
    }

    func testAccessibilityFilterActionsAndSearchRemainReachable() throws {
        let app = launch(screen: "spending", accessibilityText: true)
        openMoreFilters(in: app)
        XCTAssertTrue(app.buttons["transaction-filter-apply"].isHittable)
        XCTAssertTrue(app.buttons["transaction-filter-cancel"].isHittable)
        screenshot("structured-filter-accessibility-actions", app: app)
        let scroll = app.scrollViews["transaction-filter-review-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let selector = app.buttons["transaction-filter-select-payee"]
        let navigation = app.navigationBars["Transaction Filters"]
        let footer = app.buttons["transaction-filter-clear"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        for _ in 0..<12 {
            if isFullyVisible(selector.frame, in: scroll, below: navigation, above: footer) { break }
            scrollReviewBySmallStep(in: app, scroll: scroll, below: navigation, above: footer)
        }
        let selectorIsVisible = isFullyVisible(selector.frame, in: scroll, below: navigation, above: footer)
        XCTAssertTrue(selectorIsVisible, "Payee destination must fit visibly between navigation and fixed actions")
        guard selectorIsVisible else { return }
        app.coordinate(withNormalizedOffset: CGVector(
            dx: selector.frame.midX / app.frame.width,
            dy: selector.frame.midY / app.frame.height
        )).tap()
        XCTAssertTrue(app.navigationBars["Payee"].waitForExistence(timeout: 5))
        let search = app.textFields["transaction-filter-options-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        search.typeText("market")
        screenshot("structured-filter-accessibility-search-keyboard", app: app)
        app.navigationBars["Payee"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["transaction-filter-cancel"].isHittable)
        app.buttons["transaction-filter-cancel"].tap()
    }

    private func launch(
        screen: String,
        accessibilityText: Bool = false,
        replaceDemo: Bool = true
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        if replaceDemo {
            app.launchArguments.append("-actualist-replace-demo-for-ui-testing")
        }
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let title: String?
        switch screen {
        case "spending": title = "Spending"
        case "accounts": title = "Accounts"
        case "budget": title = nil
        default: title = screen
        }
        if let title {
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15))
        } else {
            XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        }
        return app
    }

    private func openMoreFilters(in app: XCUIApplication) {
        app.buttons["Transaction Actions"].tap()
        app.buttons["Filter Transactions"].tap()
        let more = app.buttons["transaction-more-filters"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(app.navigationBars["Transaction Filters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transaction-filter-apply"].waitForExistence(timeout: 5))
    }

    @discardableResult
    private func selectFirstOption(field: String, in app: XCUIApplication) -> String {
        let selector = app.buttons["transaction-filter-select-\(field)"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        for _ in 0..<5 where !selector.isHittable { app.swipeUp() }
        XCTAssertTrue(selector.isHittable, "Filter destination is not reachable: \(field)")
        selector.tap()
        XCTAssertTrue(app.navigationBars[field.capitalized].waitForExistence(timeout: 5))

        let option = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "transaction-filter-option-\(field)-")
        ).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10), "No options loaded for \(field)")
        let title = option.label
        option.tap()
        screenshot("structured-filter-\(field)-selection", app: app)
        app.navigationBars[field.capitalized].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Transaction Filters"].waitForExistence(timeout: 5))
        return title
    }

    private func selectStatus(_ status: String, in app: XCUIApplication) {
        app.buttons["Transaction Actions"].tap()
        app.buttons["Filter Transactions"].tap()
        app.buttons[status].tap()
        XCTAssertTrue(app.buttons["Clear \(status) Filter"].waitForExistence(timeout: 5))
    }

    private func openNativeAppearance(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        if isWide(app) {
            let settings = app.collectionViews["Sidebar"].cells.containing(
                .staticText,
                identifier: "Settings"
            ).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        } else {
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.cells.containing(.staticText, identifier: "Appearance").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    }

    private func restoreDarkAppearance() {
        let app = launch(screen: "budget", replaceDemo: false)
        openNativeAppearance(in: app)
        let theme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        if theme.waitForExistence(timeout: 5) {
            theme.tap()
            let darkTheme = app.buttons["Actual Purple (dark)"]
            if darkTheme.waitForExistence(timeout: 3) { darkTheme.tap() }
        }
        app.terminate()
    }

    private func openCheckingAccount(in app: XCUIApplication) {
        if isWide(app) {
            let account = app.collectionViews["Sidebar"].staticTexts["Everyday Checking"]
            XCTAssertTrue(account.waitForExistence(timeout: 8))
            account.tap()
        } else {
            let account = app.buttons["account-row-checking"]
            XCTAssertTrue(account.waitForExistence(timeout: 8))
            account.tap()
        }
    }

    private func isWide(_ app: XCUIApplication) -> Bool {
        app.frame.width >= 792
    }

    private func isFullyVisible(
        _ elementFrame: CGRect,
        in scroll: XCUIElement,
        below navigation: XCUIElement,
        above footer: XCUIElement
    ) -> Bool {
        let visibleTop = max(scroll.frame.minY, navigation.frame.maxY)
        let visibleBottom = min(scroll.frame.maxY, footer.frame.minY)
        return elementFrame.minY >= visibleTop
            && elementFrame.maxY <= visibleBottom
            && elementFrame.width > 0
            && elementFrame.height > 0
    }

    private func scrollReviewBySmallStep(
        in app: XCUIApplication,
        scroll: XCUIElement,
        below navigation: XCUIElement,
        above footer: XCUIElement
    ) {
        let visibleTop = max(scroll.frame.minY, navigation.frame.maxY)
        let visibleBottom = min(scroll.frame.maxY, footer.frame.minY)
        let visibleHeight = visibleBottom - visibleTop
        guard visibleHeight > 0 else {
            XCTFail("Transaction filter review has no scroll space above its fixed actions")
            return
        }

        let start = app.coordinate(withNormalizedOffset: CGVector(
            dx: scroll.frame.midX / app.frame.width,
            dy: (visibleTop + visibleHeight * 0.78) / app.frame.height
        ))
        let end = app.coordinate(withNormalizedOffset: CGVector(
            dx: scroll.frame.midX / app.frame.width,
            dy: (visibleTop + visibleHeight * 0.56) / app.frame.height
        ))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
