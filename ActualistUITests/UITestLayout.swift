import XCTest

extension XCUIApplication {
    /// The adaptive root is a native tab bar in the compact layout and a sidebar
    /// split view in the wide layout. Window width alone is not a reliable
    /// signal: an iPad at accessibility Dynamic Type sizes deliberately uses the
    /// compact layout, and iPhone Duo's side-docked tabs are not a tab bar to
    /// XCUITest. A window under 792 points never fits the sidebar layout. Call
    /// this after the first screen has loaded.
    var usesCompactLayout: Bool { frame.width < 792 || tabBars.firstMatch.exists }
}

extension XCTestCase {
    /// Skips an iPhone-layout test on the wide iPad layout, naming the test that
    /// covers the wide equivalent so the skip is traceable.
    @MainActor func requireCompactLayout(_ app: XCUIApplication, wideCoverage: String) throws {
        guard app.usesCompactLayout else {
            throw XCTSkip("Requires the compact tab bar layout; wide equivalent: \(wideCoverage)")
        }
    }
}
