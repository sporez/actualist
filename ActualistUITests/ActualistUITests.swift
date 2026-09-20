import XCTest
import AppIntents

@MainActor
final class ActualistUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCompactBudgetKeepsNativeTabsAndBottomAddTransaction() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        try requireCompact(app)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 5))
        attachScreenshot(named: "compact-budget-top", app: app)
        assertFinalCompactBudgetContentClearsBottomControls(in: app)
        attachScreenshot(named: "compact-budget-bottom", app: app)
    }

    @MainActor
    func testPortraitIPadBudgetScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 5))
        attachScreenshot(named: "ipad-portrait-budget", app: app)
    }

    @MainActor
    func testAccessibilityTextSizeKeepsBudgetUsable() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo(dynamicType: "UICTContentSizeCategoryAccessibilityXXXL")

        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 15))
        XCTAssertFalse(budgetGrid(in: app).exists)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        assertAccessibilityBudgetLayout(in: app)
        attachScreenshot(named: "accessibility-xxxl-budget-top", app: app)
        assertFinalCompactBudgetContentClearsBottomControls(in: app)
        attachScreenshot(named: "accessibility-xxxl-budget-bottom", app: app)
    }

    @MainActor
    func testAppearanceSupportsDarkAndLightThemes() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo(screen: "settings/appearance")
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 10))
        let themePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(themePicker.waitForExistence(timeout: 5))
        themePicker.tap()
        app.buttons["Actual Purple (dark)"].tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        attachScreenshot(named: "ipad-appearance-dark", app: app)

        themePicker.tap()
        let lightTheme = app.buttons["Actual Purple (light)"]
        XCTAssertTrue(lightTheme.waitForExistence(timeout: 5))
        lightTheme.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(themePicker.label.contains("Actual Purple (light)"))
        attachScreenshot(named: "ipad-appearance-light", app: app)
        app.terminate()
        let lightBudget = launchDemo()
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 10))
        attachScreenshot(named: "ipad-budget-light", app: lightBudget)
        lightBudget.terminate()
        let settings = launchDemo(screen: "settings/appearance")
        let restorePicker = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(restorePicker.waitForExistence(timeout: 10))
        restorePicker.tap()
        settings.buttons["Actual Purple (dark)"].tap()
    }

    @MainActor
    func testTransactionDraftSurvivesRotationIntoCompactLayout() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        guard app.frame.height < 792 else { throw XCTSkip("Requires an iPad with compact portrait width") }
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 15))
        app.buttons["Add Transaction"].tap()
        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("1234")
        let amount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertLessThan(app.frame.width, 792)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(amount.exists)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let editorScroll = app.scrollViews["transaction-editor-scroll"]
        XCTAssertTrue(editorScroll.waitForExistence(timeout: 5))
        let notes = app.descendants(matching: .any)["transaction-notes-field"]
        scroll(notes, fullyAbove: keyboard, in: editorScroll)
        XCTAssertTrue(notes.isHittable)
        notes.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        let save = app.descendants(matching: .any)["transaction-save-button"]
        scroll(save, fullyAbove: keyboard, in: editorScroll)
        XCTAssertLessThanOrEqual(save.frame.maxY, keyboard.frame.minY - 4)
        XCTAssertTrue(editor.buttons.firstMatch.isHittable)
        XCTAssertTrue(amount.exists)
        XCTAssertTrue(amount.label.contains("12.34"))
        attachScreenshot(named: "transaction-draft-lower-fields-after-rotation", app: app)
        editor.buttons.firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertFalse(budgetGrid(in: app).exists)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Spending"].firstMatch.exists)
        attachScreenshot(named: "compact-ipad-after-rotation", app: app)
    }

    @MainActor
    func testWideBudgetUsesSidebarAndToolbarAction() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Budget"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 5))
        attachScreenshot(named: "wide-budget", app: app)
    }

    @MainActor
    func testWideBudgetAssignmentPopoverSupportsCancel() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))
        let assigned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'"))
        XCTAssertTrue(assigned.firstMatch.waitForExistence(timeout: 5))
        assigned.firstMatch.tap()
        XCTAssertTrue(assignmentPopover(in: app).waitForExistence(timeout: 5))
        attachScreenshot(named: "wide-assignment-review", app: app)
        app.buttons["Dismiss keypad"].tap()
        XCTAssertFalse(assignmentPopover(in: app).exists)
    }

    @MainActor
    func testWideBudgetActionsExposeMonthPreference() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))
        app.buttons["Budget Actions"].tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Months Shown'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        XCTAssertTrue(app.buttons["Auto"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["5"].exists)
        app.buttons["1"].tap()
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(visibleMonthCount(in: app), 1)
        attachScreenshot(named: "wide-fixed-one-month", app: app)
        app.buttons["Budget Actions"].tap()
        picker.tap()
        app.buttons["Auto"].tap()
        XCTAssertGreaterThan(visibleMonthCount(in: app), 1)
    }

    @MainActor
    func testWideBudgetAssignmentSaveChangesTheAssignedCell() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))

        let assigned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'"))
        let cell = assigned.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        let before = cell.label
        cell.tap()
        let popover = app.descendants(matching: .any)
            .matching(identifier: "assignment-popover")
            .firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        app.buttons[before.hasSuffix("0.01") ? "2" : "1"].tap()
        app.buttons["Save assignment"].tap()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(cell.label, before)
        attachScreenshot(named: "wide-assignment-saved", app: app)
    }

    @MainActor
    func testWideBudgetCategoryInspectorChromeInBothSidebarLayouts() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))

        for preference in ["Auto", "1"] {
            app.buttons["Budget Actions"].tap()
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Months Shown'")).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            picker.tap()
            app.buttons[preference].tap()

            let expectedMonthCount = preference == "1" ? 1 : 2
            let monthCountExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preference == "1"
                        ? self.visibleMonthCount(in: app) == expectedMonthCount
                        : self.visibleMonthCount(in: app) >= expectedMonthCount
                },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [monthCountExpectation], timeout: 5), .completed)

            let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'available-'")).firstMatch
            XCTAssertTrue(category.waitForExistence(timeout: 5))
            let month = category.label.components(separatedBy: ", ")[1]
            category.tap()

            let inspector = app.collectionViews.matching(identifier: "budget-category-inspector").firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 5))
            XCTAssertTrue(inspector.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", month)).firstMatch.waitForExistence(timeout: 3))

            for controlName in ["Close Category Details", "Search Transactions", "Add Transaction"] {
                let control = app.buttons[controlName]
                XCTAssertTrue(control.waitForExistence(timeout: 3))
                XCTAssertGreaterThanOrEqual(control.frame.minX, inspector.frame.minX)
                XCTAssertLessThanOrEqual(control.frame.maxX, inspector.frame.maxX)
            }

            attachScreenshot(named: "wide-category-inspector-\(preference.lowercased())", app: app)
            app.buttons["Close Category Details"].tap()
            XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
        }

        app.buttons["Budget Actions"].tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Months Shown'")).firstMatch
        picker.tap()
        app.buttons["Auto"].tap()
    }

    @MainActor
    func testWideBudgetRootAddTransactionCategoryPickerReturnsToEditor() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))

        app.buttons["Add Transaction"].tap()
        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        dismissNumberPadPopover(in: app, editor: editor)
        let categoryRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Category'")).firstMatch
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 5))
        categoryRow.tap()

        let categoryPicker = app.navigationBars["Category"]
        XCTAssertTrue(categoryPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search Categories"].waitForExistence(timeout: 3))
        categoryPicker.buttons.firstMatch.tap()
        XCTAssertTrue(categoryPicker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        editor.buttons.firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testWideSidebarSwitchesAccountsAndAccountEditorRemainsInteractive() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)

        let sidebar = app.collectionViews["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        let checking = sidebar.staticTexts["Everyday Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 15))
        checking.tap()
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))

        let savings = sidebar.staticTexts["High-Yield Savings"]
        XCTAssertTrue(savings.waitForExistence(timeout: 5))
        savings.tap()
        XCTAssertTrue(app.navigationBars["High-Yield Savings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Everyday Checking"].exists)

        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 5))
        XCTAssertTrue(addTransaction.isHittable)
        addTransaction.tap()

        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("1234")
        let amount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        attachScreenshot(named: "wide-sidebar-savings-editor", app: app)
        dismissNumberPadPopover(in: app, editor: editor)
        let close = editor.buttons.firstMatch
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["High-Yield Savings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWideAccountsOverviewTransactionEditorRemainsInteractive() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo(screen: "accounts")
        try requireWide(app)

        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 15))
        let addAccount = app.buttons["Add Account"]
        let addTransaction = app.buttons["Add Transaction"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 5))
        XCTAssertTrue(addTransaction.isHittable)
        addTransaction.tap()

        let editor = app.navigationBars["Add Transaction"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("1234")
        let amount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        attachScreenshot(named: "wide-accounts-overview-transaction-editor", app: app)

        dismissNumberPadPopover(in: app, editor: editor)
        let close = editor.buttons.firstMatch
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWideBudgetMonthNavigationAndNamedMonthPickerShiftAssignedCells() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))

        let initialAnchor = try XCTUnwrap(assignedAnchorMonth(in: app))
        let previousAnchor = try XCTUnwrap(monthID(initialAnchor, offsetBy: -1))

        app.buttons["Previous month"].tap()
        XCTAssertTrue(waitForAssignedAnchor(in: app, equalTo: previousAnchor))

        app.buttons["Next month"].tap()
        XCTAssertTrue(waitForAssignedAnchor(in: app, equalTo: initialAnchor))

        app.buttons["Current month"].tap()
        XCTAssertTrue(waitForAssignedAnchor(in: app, equalTo: currentMonthID()))

        let monthButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose budget month,'")).firstMatch
        XCTAssertTrue(monthButton.waitForExistence(timeout: 5))
        monthButton.tap()
        let picker = app.buttons["Jun"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        XCTAssertTrue(waitForAssignedAnchor(in: app, equalTo: String(format: "%04d-06", currentYear)))
    }

    @MainActor
    func testWideCategoryInspectorKeepsAddTransactionAndSwitchesCategory() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))

        let available = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'available-'"))
        XCTAssertTrue(available.firstMatch.waitForExistence(timeout: 5))
        let first = available.firstMatch
        let firstCategory = first.label.components(separatedBy: ", ").first ?? ""
        first.tap()

        let inspector = app.collectionViews.matching(identifier: "budget-category-inspector").firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 3))

        let second = available.allElementsBoundByIndex.first {
            ($0.label.components(separatedBy: ", ").first ?? "") != firstCategory
        }
        guard let second else { throw XCTSkip("Demo has one available category") }
        let secondCategory = second.label.components(separatedBy: ", ").first ?? ""
        second.tap()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(identifier: "budget-category-inspector")
            .matching(NSPredicate(format: "label == %@", secondCategory)).firstMatch.waitForExistence(timeout: 5))
        XCTAssertNotEqual(firstCategory, secondCategory)

        app.buttons["Close Category Details"].tap()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testWideCategoryInspectorPreservesScrolledGridPosition() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        let grid = budgetGrid(in: app)
        XCTAssertTrue(grid.waitForExistence(timeout: 15))

        let sentinel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "available-")).firstMatch
        XCTAssertTrue(sentinel.waitForExistence(timeout: 5))
        let initialSentinelY = sentinel.frame.minY
        grid.swipeUp()
        let movedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = sentinel.frame
                return frame != .zero && frame.minY < initialSentinelY - 20
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [movedExpectation], timeout: 5), .completed)

        let vacation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'available-' AND identifier ENDSWITH '-vacation'")).firstMatch
        XCTAssertTrue(vacation.waitForExistence(timeout: 5))
        XCTAssertTrue(vacation.isHittable)
        let month = vacation.label.components(separatedBy: ", ")[1]
        let beforeX = vacation.frame.minX
        let beforeY = vacation.frame.minY
        attachScreenshot(named: "inspector-scroll-before", app: app)

        vacation.tap()
        let inspector = app.collectionViews.matching(identifier: "budget-category-inspector").firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts
            .matching(identifier: "budget-category-inspector")
            .matching(NSPredicate(format: "label == 'Vacation'"))
            .firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(inspector.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", month))
            .firstMatch
            .waitForExistence(timeout: 5))

        app.buttons["Close Category Details"].tap()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
        attachScreenshot(named: "inspector-scroll-after", app: app)
        let returnedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(vacation.frame.minY - beforeY) < 12 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returnedExpectation], timeout: 5), .completed,
                       "Vacation row moved from \(beforeY) to \(vacation.frame.minY)")
        XCTAssertEqual(vacation.frame.minX, beforeX, accuracy: 1)
    }

    @MainActor
    func testNativeWindowResizeTransitionsThroughWideSidebarAndCompactModes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        var nativeResizeAvailable = false

        if window.frame.width < 1_000 || visibleMonthCount(in: app) <= 1 {
            guard resizeWindow(window, by: 60) else {
                throw XCTSkip("Native iPad window resizing is unavailable in this run")
            }
            nativeResizeAvailable = true
            for _ in 0..<12 where window.frame.width < 1_000 || visibleMonthCount(in: app) <= 1 {
                XCTAssertTrue(resizeWindow(window, by: 60))
            }
        }

        let initialWidth = window.frame.width
        let initialAnchor = try XCTUnwrap(assignedAnchorMonth(in: app))
        XCTAssertGreaterThan(visibleMonthCount(in: app), 1)
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        defer {
            if nativeResizeAvailable {
                var attempts = 0
                while window.frame.width < initialWidth - 24 && attempts < 20 {
                    _ = resizeWindow(window, by: 60)
                    attempts += 1
                }
            }
        }

        if !nativeResizeAvailable {
            guard resizeWindow(window, by: -60) else {
                throw XCTSkip("Native iPad window resizing is unavailable in this run")
            }
            nativeResizeAvailable = true
        } else {
            XCTAssertTrue(resizeWindow(window, by: -60))
        }

        var reachedSidebarSingleMonth = false
        for _ in 0..<12 where !reachedSidebarSingleMonth {
            if window.frame.width >= 792,
               !app.tabBars.firstMatch.exists,
               visibleMonthCount(in: app) == 1 {
                reachedSidebarSingleMonth = true
                break
            }
            XCTAssertTrue(resizeWindow(window, by: -60))
        }
        XCTAssertTrue(reachedSidebarSingleMonth)
        XCTAssertGreaterThanOrEqual(window.frame.width, 792)

        var reachedCompact = false
        for _ in 0..<6 where !reachedCompact {
            XCTAssertTrue(resizeWindow(window, by: -60))
            reachedCompact = window.frame.width < 792 && app.tabBars.firstMatch.exists
        }
        XCTAssertTrue(reachedCompact)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Transaction"].waitForExistence(timeout: 5))
        assertFinalCompactBudgetContentClearsBottomControls(in: app)
        attachScreenshot(named: "stage-manager-compact-bottom", app: app)

        var returnedToSidebar = false
        for _ in 0..<8 where !returnedToSidebar {
            XCTAssertTrue(resizeWindow(window, by: 60))
            returnedToSidebar = window.frame.width >= 792 && !app.tabBars.firstMatch.exists
        }
        XCTAssertTrue(returnedToSidebar)
        XCTAssertTrue(app.staticTexts["Budget"].waitForExistence(timeout: 5))
        XCTAssertEqual(visibleMonthCount(in: app), 1)

        var restoredWide = false
        for _ in 0..<20 where !restoredWide {
            if window.frame.width >= initialWidth - 24 {
                restoredWide = true
                break
            }
            XCTAssertTrue(resizeWindow(window, by: 60))
        }
        XCTAssertTrue(restoredWide)
        XCTAssertEqual(window.frame.width, initialWidth, accuracy: 24)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertGreaterThan(visibleMonthCount(in: app), 1)
        XCTAssertEqual(assignedAnchorMonth(in: app), initialAnchor)
    }

    @MainActor
    func testWideResizeRetainsAnchorInLightTheme() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let settings = launchDemo(screen: "settings/appearance")
        try requireWide(settings)
        let picker = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        settings.buttons["Actual Purple (light)"].tap()
        settings.terminate()
        let app = launchDemo()
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        let initialWidth = window.frame.width
        let anchor = try XCTUnwrap(assignedAnchorMonth(in: app))
        defer {
            app.terminate()
            let restored = launchDemo(screen: "settings/appearance")
            let theme = restored.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
            if theme.waitForExistence(timeout: 10) {
                theme.tap()
                restored.buttons["Actual Purple (dark)"].tap()
            }
        }
        for _ in 0..<3 {
            XCTAssertTrue(resizeWindow(window, by: -60))
            XCTAssertEqual(assignedAnchorMonth(in: app), anchor)
            XCTAssertTrue(resizeWindow(window, by: 60))
        }
        XCTAssertEqual(window.frame.width, initialWidth, accuracy: 24)
        XCTAssertEqual(assignedAnchorMonth(in: app), anchor)
        attachScreenshot(named: "resize-light-reversals", app: app)
        try testNativeWindowResizeTransitionsThroughWideSidebarAndCompactModes()
    }

    @MainActor
    func testReduceMotionResize() throws {
        XCUIDevice.shared.orientation = .portrait
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        try requireWide(settings)
        settings.buttons["com.apple.settings.accessibility"].tap()
        settings.buttons["MOTION_TITLE"].tap()
        let reduceMotion = settings.switches["REDUCE_MOTION"]
        XCTAssertTrue(reduceMotion.waitForExistence(timeout: 5))
        let original = reduceMotion.value as? String
        if original != "1" { reduceMotion.switches.firstMatch.tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: reduceMotion)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        defer {
            settings.activate()
            if reduceMotion.value as? String != original { reduceMotion.switches.firstMatch.tap() }
        }
        try testNativeWindowResizeTransitionsThroughWideSidebarAndCompactModes()
    }

    @MainActor
    func testWideBudgetLargeTextKeepsColumnsAligned() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo(dynamicType: "UICTContentSizeCategoryXXXL")
        try requireWide(app)
        XCTAssertTrue(budgetGrid(in: app).waitForExistence(timeout: 15))
        let assigned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-' AND identifier ENDSWITH '-groceries'")).firstMatch
        let available = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'available-' AND identifier ENDSWITH '-groceries'")).firstMatch
        XCTAssertTrue(assigned.waitForExistence(timeout: 5))
        XCTAssertEqual(assigned.frame.midY, available.frame.midY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(available.frame.minX, assigned.frame.maxX)
        attachScreenshot(named: "resize-large-type", app: app)
    }

    @MainActor
    private func launchDemo(
        screen: String = "budget",
        dynamicType: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        if let dynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicType]
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func requireWide(_ app: XCUIApplication) throws {
        guard app.frame.width >= 792 else { throw XCTSkip("Requires a wide native window") }
    }

    private func requireCompact(_ app: XCUIApplication) throws {
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact native window") }
    }

    private func budgetGrid(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "budget-grid").firstMatch
    }

    private func assignmentPopover(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assignment-popover").firstMatch
    }

    private func assertAccessibilityBudgetLayout(in app: XCUIApplication) {
        let alert = app.buttons["budget-alert-uncategorizedTransactions"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.label.contains("Uncategorized transactions"))
        XCTAssertTrue(alert.label.contains("Review"))
        XCTAssertGreaterThan(alert.frame.height, 100)

        let group = app.buttons["budget-group-essentials"]
        let firstCategory = app.buttons["budget-category-rent"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(firstCategory.waitForExistence(timeout: 5))
        XCTAssertTrue(group.label.contains("Essentials"))
        XCTAssertTrue(group.label.contains("Assigned"))
        XCTAssertTrue(group.label.contains("Available"))
        XCTAssertGreaterThan(group.frame.height, 120)
        XCTAssertLessThanOrEqual(group.frame.maxY, firstCategory.frame.minY)
        XCTAssertFalse(group.frame.intersects(firstCategory.frame))
        XCTAssertGreaterThan(firstCategory.frame.height, 120)
    }

    private func assertFinalCompactBudgetContentClearsBottomControls(in app: XCUIApplication) {
        let scrollView = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        let finalCategory = app.buttons["budget-category-retirement"]
        let addTransaction = app.buttons["Add Transaction"]
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(addTransaction.waitForExistence(timeout: 5))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        for _ in 0..<12 {
            let clearanceY = min(addTransaction.frame.minY, tabBar.frame.minY) - 4
            if finalCategory.exists,
               finalCategory.frame != .zero,
               finalCategory.frame.maxY <= clearanceY,
               finalCategory.isHittable {
                break
            }
            scrollView.swipeUp()
        }

        XCTAssertTrue(finalCategory.waitForExistence(timeout: 3))
        XCTAssertTrue(finalCategory.isHittable)
        XCTAssertLessThanOrEqual(finalCategory.frame.maxY, addTransaction.frame.minY - 4)
        XCTAssertLessThanOrEqual(finalCategory.frame.maxY, tabBar.frame.minY - 4)
    }

    private func scroll(_ element: XCUIElement, fullyAbove occluder: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<8 {
            if element.exists,
               element.frame != .zero,
               element.frame.minY >= scrollView.frame.minY,
               element.frame.maxY <= occluder.frame.minY - 4 {
                return
            }
            scrollView.swipeUp()
        }
        XCTAssertTrue(element.exists)
        XCTAssertGreaterThanOrEqual(element.frame.minY, scrollView.frame.minY)
        XCTAssertLessThanOrEqual(element.frame.maxY, occluder.frame.minY - 4)
    }

    private func visibleMonthCount(in app: XCUIApplication) -> Int {
        assignedMonthIDs(in: app).count
    }

    private func assignedMonthIDs(in app: XCUIApplication) -> Set<String> {
        Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'"))
            .allElementsBoundByIndex
            .compactMap { element in
                let parts = element.identifier.split(separator: "-")
                guard parts.count >= 3 else { return nil }
                return parts.prefix(3).joined(separator: "-")
            })
    }

    private func assignedAnchorMonth(in app: XCUIApplication) -> String? {
        guard let month = assignedMonthIDs(in: app).sorted().first else { return nil }
        return String(month.dropFirst("assigned-".count))
    }

    private func waitForAssignedAnchor(
        in app: XCUIApplication,
        equalTo month: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        let predicate = NSPredicate { _, _ in self.assignedAnchorMonth(in: app) == month }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    private func currentMonthID() -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", components.year ?? 1970, components.month ?? 1)
    }

    private func monthID(_ month: String, offsetBy offset: Int) -> String? {
        let input = DateFormatter()
        input.calendar = Calendar(identifier: .gregorian)
        input.dateFormat = "yyyy-MM"
        guard let date = input.date(from: month),
              let shifted = input.calendar.date(byAdding: .month, value: offset, to: date) else {
            return nil
        }
        return input.string(from: shifted)
    }

    private func resizeWindow(_ window: XCUIElement, by deltaX: CGFloat, timeout: TimeInterval = 5) -> Bool {
        guard abs(deltaX) > 20 else { return true }
        let before = window.frame.width
        let handle = window.coordinate(
            withNormalizedOffset: CGVector(dx: 1, dy: 1)
        ).withOffset(CGVector(dx: -8, dy: -8))
        handle.press(
            forDuration: 0.5,
            thenDragTo: handle.withOffset(CGVector(dx: deltaX, dy: 0))
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(window.frame.width - before) > 20 },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
