import XCTest

extension XCTestCase {
    /// Shows an absolute month on the compact Budget screen through the month
    /// picker. The bundled demo's data ends 2026-08, so tests that need real
    /// data must not depend on the month the run date happens to open on.
    @MainActor
    func selectCompactBudgetMonth(year: Int, abbreviation: String, in app: XCUIApplication) {
        let monthButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label MATCHES %@", ".*[A-Z][a-z]{2} 20[0-9]{2}$")
        ).firstMatch
        XCTAssertTrue(monthButton.waitForExistence(timeout: 15))
        monthButton.tap()
        let displayedYear = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "20[0-9]{2}")).firstMatch
        XCTAssertTrue(displayedYear.waitForExistence(timeout: 5))
        for _ in 0..<10 where displayedYear.label != String(year) {
            let earlier = (Int(displayedYear.label) ?? year) > year
            let chevron = app.buttons.matching(NSPredicate(
                format: earlier ? "identifier == 'chevron.left' OR label == 'Back'" : "identifier == 'chevron.right' OR label == 'Forward'"
            )).firstMatch
            XCTAssertTrue(chevron.waitForExistence(timeout: 3))
            chevron.tap()
        }
        XCTAssertEqual(displayedYear.label, String(year))
        app.buttons[abbreviation].tap()
    }

    /// Steps the wide grid back until the given month's column is visible.
    @MainActor
    func stepWideBudgetGrid(toShow monthID: String, in app: XCUIApplication) {
        let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "available-\(monthID)-")).firstMatch
        for _ in 0..<48 where !marker.exists {
            app.buttons["Previous month"].tap()
        }
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "Month \(monthID) never became visible")
    }
}
