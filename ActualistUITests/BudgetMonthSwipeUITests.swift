import XCTest
import UIKit

final class BudgetMonthSwipeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testEdgeMonthNavigationAndScrollCoexist() throws {
        let app = launch()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let original = title(app)
        drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
        XCTAssertTrue(waitForTitleChange(app, from: original), "\(scroll.value ?? "nil")")
        let next = title(app)
        XCTAssertNotEqual(next, original)
        capture("month-next", app)
        drag(scroll, from: .init(dx: 0.01, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
        XCTAssertTrue(waitForTitle(app, original))

        drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.9, dy: 0.5))
        XCTAssertEqual(title(app), original)
        drag(scroll, from: .init(dx: 0.65, dy: 0.5), to: .init(dx: 0.15, dy: 0.5))
        XCTAssertEqual(title(app), original)
        XCTAssertFalse(app.buttons["Save assignment"].exists)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'budget-category-'" )).firstMatch
        XCTAssertTrue(first.exists)
        let before = first.frame.minY
        drag(scroll, from: .init(dx: 0.01, dy: 0.8), to: .init(dx: 0.025, dy: 0.3))
        XCTAssertEqual(title(app), original)
        XCTAssertTrue(!first.exists || before - first.frame.minY > 60)
        capture("month-edge-scroll", app)
    }

    @MainActor func testShortSwipesSpringBackAndCommittedSlideFinishes() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.buttons["com.apple.settings.accessibility"].tap()
        settings.buttons["MOTION_TITLE"].tap()
        let toggle = settings.switches["REDUCE_MOTION"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = toggle.value as? String
        if original == "1" { toggle.switches.firstMatch.tap() }
        defer {
            settings.activate()
            if toggle.value as? String != original { toggle.switches.firstMatch.tap() }
        }
        let app = launch()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let row = app.buttons["budget-category-rent"]
        let originalFrame = row.frame
        let originalTitle = title(app)
        for (start, end) in [(0.99, 0.81), (0.01, 0.19)] {
            scroll.coordinate(withNormalizedOffset: .init(dx: start, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: end, dy: 0.5)),
                withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.25)
            XCTAssertTrue(waitForEnabled(row))
            XCTAssertEqual(title(app), originalTitle)
            XCTAssertEqual(row.frame.minX, originalFrame.minX, accuracy: 1)
            XCTAssertEqual(row.frame.minY, originalFrame.minY, accuracy: 1)
            XCTAssertFalse(app.buttons["Save assignment"].exists)
        }
        scroll.coordinate(withNormalizedOffset: .init(dx: 0.99, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.64, dy: 0.5)),
            withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0)
        XCTAssertTrue(waitForTitleChange(app, from: originalTitle))
        XCTAssertTrue(waitForEnabled(row))
        XCTAssertEqual(row.frame.minX, originalFrame.minX, accuracy: 1)
        XCTAssertEqual(row.frame.minY, originalFrame.minY, accuracy: 1)
        capture("month-full-slide-complete", app)
    }

    @MainActor func testSettledRowsKeepTheirBrightness() throws {
        let app = launch()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let identifiers = ["rent", "groceries", "utilities", "transportation", "insurance"]
        let rows = identifiers.map { app.buttons["budget-category-\($0)"] }
        let before = try rows.map { try brightness($0.screenshot()) }
        let original = title(app)
        for _ in 0..<2 {
            drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
            XCTAssertTrue(waitForTitleChange(app, from: original))
            drag(scroll, from: .init(dx: 0.01, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
            XCTAssertTrue(waitForTitle(app, original))
            drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.9, dy: 0.5))
        }
        for (index, row) in rows.enumerated() {
            XCTAssertTrue(row.isEnabled)
            XCTAssertEqual(try brightness(row.screenshot()) / before[index], 1, accuracy: 0.03, identifiers[index])
        }
        capture("settled-row-brightness", app)
    }

    private func brightness(_ screenshot: XCUIScreenshot) throws -> Double {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).reduce(0.0) {
            $0 + Double(pixels[$1]) + Double(pixels[$1 + 1]) + Double(pixels[$1 + 2])
        } / Double(image.width * image.height)
    }

    @MainActor func testScrolledMonthRoundTripRetainsPosition() throws {
        let app = launch()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        drag(scroll, from: .init(dx: 0.5, dy: 0.8), to: .init(dx: 0.5, dy: 0.45))
        let anchor = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'budget-category-'"))
            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > scroll.frame.minY + 25 })
        let identity = anchor.identifier
        let y = anchor.frame.minY
        let original = title(app)
        drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
        XCTAssertTrue(waitForTitleChange(app, from: original))
        drag(scroll, from: .init(dx: 0.01, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
        XCTAssertTrue(waitForTitle(app, original))
        XCTAssertEqual(app.buttons[identity].frame.minY, y, accuracy: 3)
        capture("month-scrolled-round-trip", app)
        scroll.swipeDown()
        scroll.swipeDown()
        XCTAssertEqual(title(app), original)
        XCTAssertFalse(app.buttons["Save assignment"].exists)
    }

    @MainActor func testPickerStillOpensAfterRejectedGesture() {
        let app = launch()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let original = title(app)
        drag(scroll, from: .init(dx: 0.5, dy: 0.7), to: .init(dx: 0.2, dy: 0.5))
        XCTAssertEqual(title(app), original)
        app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", original)).firstMatch.tap()
        XCTAssertTrue(app.buttons["Jan"].waitForExistence(timeout: 5))
        capture("month-picker-after-drag", app)
    }

    @MainActor func testRowTapAndLongPressSurviveWhileEditingBlocksSwipe() {
        let app = launch()
        let row = app.buttons["budget-category-rent"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["Save assignment"].waitForExistence(timeout: 5))
        let original = title(app)
        app.buttons["7"].tap()
        let scroll = app.scrollViews["budget-compact-scroll"]
        let before = row.frame.minY
        // AX includes the safe-area inset in the scroll frame. Stay above the keypad.
        let visibleHeight = app.buttons["Dismiss keypad"].frame.minY - 44 - scroll.frame.minY
        let origin = scroll.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(.init(dx: 4, dy: visibleHeight * 0.85)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(.init(dx: 8, dy: 20)))
        XCTAssertGreaterThan(before - row.frame.minY, 30)
        origin.withOffset(.init(dx: scroll.frame.width - 4, dy: visibleHeight * 0.5)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(.init(dx: scroll.frame.width * 0.5, dy: visibleHeight * 0.5)))
        XCTAssertEqual(title(app), original)
        XCTAssertTrue(app.buttons["Save assignment"].exists)
        app.buttons["Dismiss keypad"].tap()
        XCTAssertTrue(app.buttons["Save assignment"].waitForNonExistence(timeout: 5))
        scroll.swipeDown()
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Notes"].waitForExistence(timeout: 5))
        capture("month-row-context-menu", app)
    }

    @MainActor func testAssignmentDismissalLeavesNoBlankScrollRegion() throws {
        let app = launchFreshDemo()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        for categoryID in ["vacation", "retirement"] {
            let row = app.buttons["budget-category-\(categoryID)"]
            for _ in 0..<5 where !row.isHittable { scroll.swipeUp() }
            XCTAssertTrue(row.isHittable)

            let originalRowMaxY = row.frame.maxY
            row.tap()
            let dismissKeypad = app.buttons["Dismiss keypad"]
            XCTAssertTrue(dismissKeypad.waitForExistence(timeout: 5))
            XCTAssertLessThan(row.frame.maxY, originalRowMaxY - 100)
            // The dismiss control begins 18 points inside the keypad, after the
            // selected row's 8-point surface gap.
            let rowToDismissControlGap = dismissKeypad.frame.minY - row.frame.maxY
            XCTAssertEqual(rowToDismissControlGap, 26, accuracy: 4)
            capture("assignment-\(categoryID)-opening-settled", app)
            dismissKeypad.tap()
            XCTAssertTrue(dismissKeypad.waitForNonExistence(timeout: 5))

            let addTransaction = app.buttons["Add Transaction"]
            XCTAssertTrue(addTransaction.waitForExistence(timeout: 5))
            XCTAssertEqual(row.frame.maxY, originalRowMaxY, accuracy: 3)
            XCTAssertGreaterThanOrEqual(row.frame.maxY, addTransaction.frame.minY - 90)
            capture("assignment-\(categoryID)-dismissal-valid-scroll", app)
        }
    }

    @MainActor func testVisibleRowEditingDoesNotExposeArtificialScrollRange() throws {
        let app = launchFreshDemo()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))

        let visibleRow = app.buttons["budget-category-rent"]
        XCTAssertTrue(visibleRow.waitForExistence(timeout: 5))
        visibleRow.tap()

        let dismissKeypad = app.buttons["Dismiss keypad"]
        XCTAssertTrue(dismissKeypad.waitForExistence(timeout: 5))
        let visibleHeight = dismissKeypad.frame.minY - 44 - scroll.frame.minY
        let origin = scroll.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<6 {
            origin.withOffset(.init(dx: scroll.frame.width * 0.5, dy: visibleHeight * 0.85))
                .press(
                    forDuration: 0.05,
                    thenDragTo: origin.withOffset(.init(dx: scroll.frame.width * 0.5, dy: visibleHeight * 0.15))
                )
        }

        let lastRow = app.buttons["budget-category-retirement"]
        XCTAssertTrue(lastRow.exists)
        XCTAssertTrue(lastRow.isHittable)
        let lastRowToDismissControlGap = dismissKeypad.frame.minY - lastRow.frame.maxY
        XCTAssertGreaterThanOrEqual(lastRowToDismissControlGap, 18)
        XCTAssertLessThanOrEqual(lastRowToDismissControlGap, 48)
        capture("assignment-visible-row-no-artificial-scroll-range", app)
    }

    @MainActor func testShownHiddenCategoryDetailsAndMoveMoneyOpen() throws {
        let app = launchFreshDemo()
        let row = app.buttons["budget-category-rent"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        app.buttons["Budget Actions"].tap()
        let showHidden = app.buttons["Show Hidden Categories"]
        XCTAssertTrue(showHidden.waitForExistence(timeout: 5))
        let initiallyShowsHidden = showHidden.value as? String == "1" || showHidden.isSelected
        showHidden.tap()
        if !initiallyShowsHidden {
            app.buttons["Budget Actions"].tap()
            XCTAssertTrue(showHidden.waitForExistence(timeout: 5))
            showHidden.tap()
        }

        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Hide"].waitForExistence(timeout: 5))
        app.buttons["Hide"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))

        app.buttons["Budget Actions"].tap()
        XCTAssertTrue(showHidden.waitForExistence(timeout: 5))
        showHidden.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        row.tap()
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 5))
        app.buttons["Details"].tap()
        XCTAssertTrue(app.navigationBars["Rent"].waitForExistence(timeout: 5))
        app.buttons["Close Category Details"].tap()
        XCTAssertTrue(app.navigationBars["Rent"].waitForNonExistence(timeout: 5))

        row.tap()
        XCTAssertTrue(app.buttons["Move Money"].waitForExistence(timeout: 5))
        app.buttons["Move Money"].tap()
        XCTAssertTrue(app.navigationBars["Move to"].waitForExistence(timeout: 5))
        capture("shown-hidden-category-actions", app)
    }

    @MainActor func testAssignmentExitPathsRestoreBottomRow() {
        let app = launchFreshDemo()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let row = app.buttons["budget-category-retirement"]
        for _ in 0..<5 where !row.isHittable { scroll.swipeUp() }
        let original = row.frame.maxY
        for action in ["Clear amount", "Save assignment", "Details"] {
            row.tap()
            XCTAssertTrue(app.buttons["Dismiss keypad"].waitForExistence(timeout: 5))
            if action == "Save assignment" { app.buttons["0"].tap() }
            app.buttons[action].tap()
            if action == "Details" {
                XCTAssertTrue(app.buttons["Close Category Details"].waitForExistence(timeout: 5))
                app.buttons["Close Category Details"].tap()
            }
            XCTAssertTrue(app.buttons["Dismiss keypad"].waitForNonExistence(timeout: 5))
            let restored = NSPredicate { _, _ in abs(row.frame.maxY - original) < 3 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 3), .completed)
        }
    }

    @MainActor func testChangingCategoryAndReturningFromAnotherTabKeepsKeypad() {
        let app = launchFreshDemo()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let last = app.buttons["budget-category-retirement"]
        for _ in 0..<5 where !last.isHittable { scroll.swipeUp() }
        let original = last.frame.maxY
        last.tap()
        XCTAssertTrue(app.buttons["Dismiss keypad"].waitForExistence(timeout: 5))
        app.buttons["budget-category-shopping"].tap()
        app.tabBars.buttons["Spending"].tap()
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(app.buttons["Dismiss keypad"].waitForExistence(timeout: 5))
        app.buttons["Dismiss keypad"].tap()
        let restored = NSPredicate { _, _ in abs(last.frame.maxY - original) < 3 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 3), .completed)
    }

    @MainActor func testLightThemeAndLargeTextSwipe() {
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        let theme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 15))
        theme.tap()
        app.buttons["Actual Purple (light)"].tap()
        setMonthSwiping(true, app: app)
        capture("month-swipe-setting-light", app)
        app.terminate()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let original = title(app)
        drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
        XCTAssertTrue(waitForTitleChange(app, from: original))
        capture("month-light-large-type", app)
        app.terminate()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        XCTAssertTrue(theme.waitForExistence(timeout: 15))
        theme.tap()
        app.buttons["Actual Purple (dark)"].tap()
    }

    @MainActor func testReduceMotionKeepsMonthNavigation() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.buttons["com.apple.settings.accessibility"].tap()
        settings.buttons["MOTION_TITLE"].tap()
        let toggle = settings.switches["REDUCE_MOTION"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = toggle.value as? String
        if original != "1" { toggle.switches.firstMatch.tap() }
        defer {
            settings.activate()
            if toggle.value as? String != original { toggle.switches.firstMatch.tap() }
        }
        let app = launch()
        let scroll = app.scrollViews["budget-compact-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let month = title(app)
        drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
        XCTAssertTrue(waitForTitleChange(app, from: month))
        capture("month-reduce-motion", app)
    }

    @MainActor func testSidebarSingleAndMultipleMonthsIgnoreEdgeDrags() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        guard app.frame.width >= 792 else { throw XCTSkip("Requires pinned iPad") }
        for preference in ["1", "Auto"] {
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Months Shown'")).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 15))
            picker.tap()
            app.buttons[preference].tap()
            app.terminate()
            app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
            app.launch()
            let grid = app.scrollViews["budget-grid"]
            XCTAssertTrue(grid.waitForExistence(timeout: 15))
            let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'" )).allElementsBoundByIndex.map(\.identifier)
            drag(grid, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'assigned-'" )).allElementsBoundByIndex.map(\.identifier), original)
            capture("month-sidebar-\(preference)", app)
            app.terminate()
            app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
            app.launch()
        }
    }

    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        setMonthSwiping(true, app: app)
        app.terminate()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        if UIDevice.current.userInterfaceIdiom == .pad {
            // The default demo fits a tall iPad. Large text makes scrolling observable.
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor private func launchFreshDemo() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "budget"
        ]
        app.launch()
        return app
    }

    @MainActor func testAppearanceToggleDisablesAndReenablesMonthSwiping() {
        let app = launch()
        for enabled in [false, true, false] {
            app.terminate()
            app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
            app.launch()
            setMonthSwiping(enabled, app: app)
            capture("month-swipe-setting-\(enabled)", app)
            app.terminate()
            app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
            app.launch()
            let scroll = app.scrollViews["budget-compact-scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 15))
            let original = title(app)
            drag(scroll, from: .init(dx: 0.99, dy: 0.5), to: .init(dx: 0.5, dy: 0.5))
            if enabled {
                XCTAssertTrue(waitForTitleChange(app, from: original))
            } else {
                XCTAssertEqual(title(app), original)
                app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", original)).firstMatch.tap()
                XCTAssertTrue(app.buttons["Jan"].waitForExistence(timeout: 5))
            }
        }
    }

    @MainActor private func setMonthSwiping(_ enabled: Bool, app: XCUIApplication) {
        let toggle = app.switches["Swipe Between Months"]
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 15))
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String != (enabled ? "1" : "0") { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
    }

    @MainActor private func title(_ app: XCUIApplication) -> String {
        app.navigationBars.firstMatch.identifier
    }

    @MainActor private func waitForTitleChange(_ app: XCUIApplication, from old: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "identifier != %@", old), object: app.navigationBars.firstMatch)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor private func waitForTitle(_ app: XCUIApplication, _ expected: String) -> Bool {
        app.navigationBars[expected].waitForExistence(timeout: 5)
    }

    @MainActor private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor private func drag(_ element: XCUIElement, from: CGVector, to: CGVector) {
        element.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: to))
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
