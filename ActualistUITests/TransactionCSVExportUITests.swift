import XCTest

@MainActor
final class TransactionCSVExportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAccountExportReviewShowsCountsAndCanCancel() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "accounts",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 15))

        if app.frame.width >= 792 {
            let checking = app.collectionViews["Sidebar"].staticTexts["Everyday Checking"]
            XCTAssertTrue(checking.waitForExistence(timeout: 8))
            checking.tap()
        } else {
            let checking = app.buttons["account-row-checking"]
            XCTAssertTrue(checking.waitForExistence(timeout: 8))
            checking.tap()
        }
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 5))

        app.buttons["Account Actions"].tap()
        let importExport = app.buttons["account-import-export-menu"]
        XCTAssertTrue(importExport.waitForExistence(timeout: 5))
        importExport.tap()
        let exportAction = app.buttons["account-export-csv"]
        XCTAssertTrue(exportAction.waitForExistence(timeout: 5))
        exportAction.tap()

        let exportTitle = app.navigationBars["Export CSV"]
        XCTAssertTrue(exportTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Transaction families"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["CSV rows"].waitForExistence(timeout: 5))
        let counts = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+$'"))
        XCTAssertEqual(counts.count, 2)
        for index in 0..<2 {
            XCTAssertGreaterThan(Int(counts.element(boundBy: index).label) ?? 0, 0)
        }

        let share = app.buttons["Share CSV…"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isHittable)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(exportTitle.waitForNonExistence(timeout: 5))
    }
}
