import XCTest

final class IPadReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSidebarAccountsOverviewClearsPreviousAccount() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        try requireWide(app)
        let sidebar = app.collectionViews["Sidebar"]
        for name in ["Everyday Checking", "High-Yield Savings"] {
            let account = sidebar.staticTexts[name]
            XCTAssertTrue(account.waitForExistence(timeout: 10))
            account.tap()
            let opened = app.navigationBars[name].waitForExistence(timeout: 5)
            if !opened {
                screenshot("review-account-navigation-failure")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(opened)
            sidebar.staticTexts.matching(identifier: "Accounts").allElementsBoundByIndex.last!.tap()
            XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Add Account"].isHittable)
        }
        screenshot("review-accounts-overview")
    }

    @MainActor
    func testDisplaySizeChangesWideRowsAndCapacity() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        var heights: [CGFloat] = []
        for (index, name) in ["dense", "compact", "comfortable", "large"].enumerated() {
            let settings = launch(screen: "settings/appearance")
            try requireWide(settings)
            XCTAssertTrue(settings.navigationBars["Appearance"].waitForExistence(timeout: 10))
            let slider = settings.sliders.firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            slider.adjust(toNormalizedSliderPosition: CGFloat(index) / 3)
            settings.terminate()
            let app = launch()
            XCTAssertTrue(app.scrollViews["budget-grid"].waitForExistence(timeout: 10))
            let amount = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'")).firstMatch
            XCTAssertTrue(amount.waitForExistence(timeout: 5))
            heights.append(amount.frame.height)
            screenshot("review-wide-density-\(name)")
            app.scrollViews["budget-grid"].swipeUp()
            screenshot("review-wide-density-\(name)-bottom")
            app.terminate()
        }
        XCTAssertTrue(zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 }, "Row heights: \(heights)")
        let settings = launch(screen: "settings/appearance")
        settings.sliders.firstMatch.adjust(toNormalizedSliderPosition: 1 / 3)
    }

    @MainActor
    func testAssignmentDraftSurvivesNativeResizeBothWays() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        try requireWide(app)
        let window = app.windows.firstMatch
        let originalWidth = window.frame.width
        XCTAssertTrue(app.scrollViews["budget-grid"].waitForExistence(timeout: 10))
        let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'")).allElementsBoundByIndex
        let months = Set(cells.map { String($0.identifier.dropFirst(9).prefix(7)) }).sorted()
        let month = try XCTUnwrap(months.last)
        let cell = try XCTUnwrap(cells.first { $0.identifier.contains(month) })
        let identity = cell.identifier
        cell.tap()
        XCTAssertTrue(app.buttons["Save assignment"].waitForExistence(timeout: 5))
        app.buttons["7"].tap()
        defer { restore(window, width: originalWidth) }
        try narrow(window, app: app)
        XCTAssertTrue(app.buttons["Save assignment"].waitForExistence(timeout: 5))
        screenshot("review-assignment-compact-retained")
        restore(window, width: originalWidth)
        XCTAssertTrue(app.buttons["Save assignment"].waitForExistence(timeout: 8))
        screenshot("review-assignment-wide-retained")
        app.buttons["Save assignment"].tap()
        XCTAssertTrue(app.buttons["Save assignment"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[identity].label.contains("0.07"))
    }

    @MainActor
    func testAssignmentDraftSurvivesItsMonthLeavingSidebarGrid() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        try requireWide(app)
        let window = app.windows.firstMatch
        let originalWidth = window.frame.width
        XCTAssertTrue(app.scrollViews["budget-grid"].waitForExistence(timeout: 10))
        let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'"))
            .allElementsBoundByIndex
        let months = Set(cells.map { String($0.identifier.dropFirst(9).prefix(7)) }).sorted()
        XCTAssertGreaterThan(months.count, 1)
        let month = try XCTUnwrap(months.last)
        let cell = try XCTUnwrap(cells.first { $0.identifier.contains(month) && $0.isHittable })
        let identity = cell.identifier
        cell.tap()
        XCTAssertTrue(app.buttons["Save assignment"].waitForExistence(timeout: 5))
        app.buttons["7"].tap()
        defer { restore(window, width: originalWidth) }
        var removed = false
        for _ in 0..<8 where !removed {
            XCTAssertTrue(resize(window, by: -60))
            XCTAssertGreaterThanOrEqual(window.frame.width, 792)
            XCTAssertTrue(app.buttons["Save assignment"].waitForExistence(timeout: 5))
            removed = !app.buttons[identity].exists
        }
        XCTAssertTrue(removed)
        screenshot("resize-departing-month-draft")
        app.buttons["Save assignment"].tap()
        XCTAssertTrue(app.buttons["Save assignment"].waitForNonExistence(timeout: 5))
        restore(window, width: originalWidth)
        XCTAssertTrue(app.buttons[identity].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons[identity].label.contains("0.07"))
    }

    @MainActor
    func testAccountEditorAndNestedPickerSurviveNativeResize() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        try requireWide(app)
        let window = app.windows.firstMatch
        let originalWidth = window.frame.width
        let checking = app.collectionViews["Sidebar"].staticTexts["Everyday Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        checking.tap()
        app.buttons["Add Transaction"].tap()
        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("1234")
        dismissNumberPadPopover(in: app, editor: editor)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Category'")).firstMatch.tap()
        let picker = app.navigationBars["Category"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        defer { restore(window, width: originalWidth) }
        try narrow(window, app: app, expectsTabs: false)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        screenshot("review-editor-picker-compact")
        picker.buttons.firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch.exists)
        restore(window, width: originalWidth)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch.exists)
        screenshot("review-editor-wide-retained")
        editor.buttons.firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testWidgetBudgetRoutesLeaveSidebarSettings() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        for (path, title) in [("action/history", "History"), ("action/uncategorized", "Uncategorized"), ("category/rent?month=2026-09", "Rent")] {
            let app = launch(screen: "settings")
            try requireWide(app)
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
            XCUIDevice.shared.system.open(URL(string: "com.sporez.actualist://" + path)!)
            if title == "Rent" {
                XCTAssertTrue(app.buttons["Close Category Details"].waitForExistence(timeout: 10))
            } else {
                XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@", title)).firstMatch.waitForExistence(timeout: 10))
            }
            screenshot("review-settings-route-\(title)")
            app.terminate()
        }
    }

    @MainActor
    func testCompactCategoryEditorCanOpenAtRoot() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        guard app.frame.width < 792 else { throw XCTSkip("Requires compact portrait width") }
        let category = app.buttons["budget-category-rent"]
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.tap()
        app.buttons["Details"].tap()
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Add Transaction"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5))
        app.typeText("1234")
        screenshot("review-compact-category-editor")
    }

    @MainActor
    func testAccountEditorAndPickerSurviveCompactRotation() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        try requireWide(app)
        guard app.frame.height < 792 else { throw XCTSkip("Requires the pinned small iPad") }
        let checking = app.collectionViews["Sidebar"].staticTexts["Everyday Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        checking.tap()
        app.buttons["Add Transaction"].tap()
        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("1234")
        dismissNumberPadPopover(in: app, editor: editor)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Category'")).firstMatch.tap()
        let picker = app.navigationBars["Category"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertLessThan(app.frame.width, 792)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        screenshot("review-account-picker-compact-rotation")
        picker.buttons.firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch.exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        screenshot("review-account-editor-restored-rotation")
        editor.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 8))
        app.collectionViews["Sidebar"].staticTexts.matching(identifier: "Accounts").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
    }

    @MainActor private func launch(screen: String = "budget") -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func requireWide(_ app: XCUIApplication) throws {
        guard app.frame.width >= 792 else { throw XCTSkip("Requires a wide iPad window") }
    }

    private func narrow(_ window: XCUIElement, app: XCUIApplication, expectsTabs: Bool = true) throws {
        for index in 0..<20 where window.frame.width >= 792 {
            if !resize(window, by: -60) {
                if index == 0 { throw XCTSkip("Native window resize unavailable") }
                XCTFail("Native resize stopped before compact mode")
                return
            }
        }
        XCTAssertLessThan(window.frame.width, 792)
        if expectsTabs { XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 8)) }
    }

    private func restore(_ window: XCUIElement, width: CGFloat) {
        for _ in 0..<20 where window.frame.width < width - 24 {
            if !resize(window, by: 60) { break }
        }
    }

    private func resize(_ window: XCUIElement, by delta: CGFloat) -> Bool {
        let width = window.frame.width
        let handle = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -8, dy: -8))
        handle.press(forDuration: 0.5, thenDragTo: handle.withOffset(CGVector(dx: delta, dy: 0)))
        let predicate = NSPredicate { _, _ in abs(window.frame.width - width) > 20 }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5) == .completed
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
