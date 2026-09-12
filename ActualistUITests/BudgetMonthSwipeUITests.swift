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

    @MainActor func testLightThemeAndLargeTextSwipe() {
        let app = XCUIApplication()
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "settings/appearance"]
        app.launch()
        let theme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 15))
        theme.tap()
        app.buttons["Actual Purple (light)"].tap()
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
        app.launchArguments = ["-actualist-demo", "-actualist-screen", "budget"]
        if UIDevice.current.userInterfaceIdiom == .pad {
            // The default demo fits a tall iPad. Large text makes scrolling observable.
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        }
        app.launch()
        return app
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
