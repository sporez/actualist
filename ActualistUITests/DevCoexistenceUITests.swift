import XCTest

@MainActor
final class DevCoexistenceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDefaultApplicationLaunchesConfiguredDevelopmentInstallation() throws {
        let appIdentifier = try UITestAppIdentity.appIdentifier
        guard appIdentifier == "com.sporez.actualist.dev" else {
            throw XCTSkip("Development installation identity regression requires the Actualist Dev scheme.")
        }
        XCTAssertEqual(try UITestAppIdentity.appDisplayName, "Actualist Dev")

        let app = XCUIApplication()
        app.launchArguments = [
            "-actualist-demo",
            "-actualist-replace-demo-for-ui-testing",
            "-actualist-screen", "budget",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.label, try UITestAppIdentity.appDisplayName)
        let budgetTab = app.tabBars.buttons["Budget"]
        XCTAssertTrue(budgetTab.waitForExistence(timeout: 15))
        XCTAssertTrue(budgetTab.isSelected)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "dev-coexistence-budget"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
