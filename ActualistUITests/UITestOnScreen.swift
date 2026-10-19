import XCTest

extension XCUIApplication {
    /// iPad keeps a keyboard element after dismissing it, parked off screen, so
    /// only a keyboard on screen counts as shown.
    @MainActor
    var isKeyboardOnScreen: Bool {
        let keyboard = keyboards.firstMatch
        return keyboard.exists && keyboard.frame.intersects(frame)
    }

    @MainActor
    func waitUntilKeyboardDismissed(timeout: TimeInterval = 5) -> Bool {
        let dismissed = NSPredicate { [self] _, _ in !isKeyboardOnScreen }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: timeout) == .completed
    }
}

extension XCUIElement {
    /// `isHittable` also accepts a row under a translucent bar at the top or in
    /// the bottom system gesture strip, where a tap never reaches the row.
    /// Clear means hittable and away from both screen edges.
    @MainActor
    func isClearOfScreenEdges(in app: XCUIApplication) -> Bool {
        guard exists, isHittable else { return false }
        let margin: CGFloat = 120
        return frame.minY >= app.frame.minY + margin && frame.maxY <= app.frame.maxY - margin
    }

    /// Scrolls a list until this element is clear of the screen edges. Each step
    /// is a drag that holds before lifting, so the list stops where the drag
    /// ends instead of coasting on and carrying the element under a bar. The
    /// last rows of a list cannot reach the middle; once a drag no longer moves
    /// the element, it only has to sit above the bottom gesture strip.
    @MainActor
    func scrollClearOfScreenEdges(in app: XCUIApplication, maxSteps: Int = 12) -> Bool {
        var previous: CGRect?
        for _ in 0..<maxSteps {
            if isClearOfScreenEdges(in: app) { return true }
            let current = exists ? frame : nil
            if let current, let previous, abs(current.minY - previous.minY) < 1 {
                return isHittable && current.maxY <= app.frame.maxY - 24
            }
            previous = current
            let height = app.frame.height
            // Unknown rows move content up by 40% of the screen; a visible row
            // moves to the middle.
            var offset = -0.4 * height
            if let current, current.height > 0 {
                offset = max(-0.4 * height, min(0.4 * height, app.frame.midY - current.midY))
            }
            // A drag this short could land as a tap on the row under it.
            if abs(offset) < 60 { offset = offset < 0 ? -60 : 60 }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: offset))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        return isClearOfScreenEdges(in: app)
    }
}
