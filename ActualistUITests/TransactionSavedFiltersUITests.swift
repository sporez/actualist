import XCTest

@MainActor
final class TransactionSavedFiltersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSaveCurrentFilterApplyThenCancelManagementAndClear() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "spending",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 15))

        openSpendingFilterMenu(in: app)
        app.buttons["Uncleared"].tap()
        XCTAssertTrue(app.buttons["Clear Uncleared Filter"].waitForExistence(timeout: 5))
        app.buttons["Search Transactions"].tap()
        let search = app.textFields["Search Transactions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("market")

        openSpendingFilterMenu(in: app)
        let moreFilters = app.buttons["transaction-more-filters"]
        XCTAssertTrue(moreFilters.waitForExistence(timeout: 5))
        moreFilters.tap()
        XCTAssertTrue(app.staticTexts["More Filters"].waitForExistence(timeout: 5))
        selectFirstCategory(in: app)
        app.buttons["transaction-filter-apply"].tap()

        openSpendingFilterMenu(in: app)
        let savedFilters = app.buttons["transaction-saved-filters"]
        XCTAssertTrue(savedFilters.waitForExistence(timeout: 5))
        savedFilters.tap()
        XCTAssertTrue(app.staticTexts["Saved Filters"].waitForExistence(timeout: 5))

        let name = "Saved Category UI Test"
        let nameField = app.textFields["saved-transaction-filter-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)
        let save = app.buttons["saved-transaction-filter-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        save.tap()

        let savedName = app.staticTexts[name]
        XCTAssertTrue(savedName.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Saved Filters"].waitForNonExistence(timeout: 5))

        let activeFilter = app.buttons["transaction-filter-clear-structured"]
        XCTAssertTrue(activeFilter.waitForExistence(timeout: 5))
        let initialClearLabel = activeFilter.staticTexts["More Filters: 1"]
        XCTAssertTrue(initialClearLabel.exists)
        XCTAssertTrue(initialClearLabel.isHittable)
        initialClearLabel.tap()
        XCTAssertTrue(activeFilter.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Clear Uncleared Filter"].exists)
        XCTAssertEqual(search.value as? String, "market")

        openSpendingFilterMenu(in: app)
        app.buttons["transaction-saved-filters"].tap()
        XCTAssertTrue(app.staticTexts["Saved Filters"].waitForExistence(timeout: 5))
        XCTAssertTrue(savedName.waitForExistence(timeout: 5))
        savedName.tap()
        XCTAssertTrue(app.staticTexts["Saved Filters"].waitForNonExistence(timeout: 5))

        XCTAssertTrue(activeFilter.waitForExistence(timeout: 5))
        XCTAssertTrue(activeFilter.label.contains("1"))
        XCTAssertTrue(app.buttons["Clear Uncleared Filter"].exists)
        XCTAssertEqual(search.value as? String, "market")

        openSpendingFilterMenu(in: app)
        app.buttons["transaction-saved-filters"].tap()
        XCTAssertTrue(app.staticTexts["Saved Filters"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Saved Filters"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(activeFilter.exists, "Dismissing filter management must not change the active query")
        XCTAssertTrue(app.buttons["Clear Uncleared Filter"].exists)
        XCTAssertEqual(search.value as? String, "market")

        let visibleClearLabel = activeFilter.staticTexts["More Filters: 1"]
        XCTAssertTrue(visibleClearLabel.exists)
        XCTAssertTrue(visibleClearLabel.isHittable)
        visibleClearLabel.tap()
        XCTAssertTrue(activeFilter.waitForNonExistence(timeout: 2))
    }

    private func selectFirstCategory(in app: XCUIApplication) {
        let selector = app.buttons["transaction-filter-select-category"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        selector.tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 5))
        let option = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "transaction-filter-option-category-")
        ).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        app.navigationBars["Category"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["More Filters"].waitForExistence(timeout: 5))
    }

    private func openSpendingFilterMenu(in app: XCUIApplication) {
        app.buttons["transaction-actions-menu"].tap()
        app.buttons["Filter Transactions"].tap()
    }
}
