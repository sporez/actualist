import XCTest
@testable import Actualist

final class AdaptiveRootPresentationModeTests: XCTestCase {
    func testCompactModeForNarrowWindow() {
        XCTAssertEqual(AdaptiveRootPresentationMode.mode(for: 791), .compact)
    }

    func testSidebarModeForWideWindow() {
        XCTAssertEqual(AdaptiveRootPresentationMode.mode(for: 792), .sidebar)
    }

    func testSidebarDestinationsPreserveCompactTabContext() {
        XCTAssertEqual(AdaptiveRootDestination(tab: .budget).appTab, .budget)
        XCTAssertEqual(AdaptiveRootDestination(tab: .spending).appTab, .spending)
        XCTAssertEqual(AdaptiveRootDestination(tab: .accounts).appTab, .accounts)
        XCTAssertEqual(AdaptiveRootDestination(tab: .reports).appTab, .reports)
        XCTAssertNil(AdaptiveRootDestination.settings.appTab)
        XCTAssertEqual(AdaptiveRootDestination.account(.init(id: "account", name: "Checking", offbudget: false, closed: false)).appTab, .accounts)
    }

    func testResizeTransitionPreservesAccountAndMapsSettingsToBudget() {
        let account = ActualAccount(id: "account", name: "Checking", offbudget: false, closed: false)
        XCTAssertEqual(
            AdaptiveRootTransition.selection(for: .sidebar, appTab: .accounts, preserving: .account(account), accountPath: [account]),
            .account(account)
        )
        XCTAssertEqual(
            AdaptiveRootTransition.selection(for: .compact, appTab: .budget, preserving: .settings),
            .budget
        )
        XCTAssertEqual(
            AdaptiveRootTransition.selection(for: .sidebar, appTab: .budget, preserving: .settings),
            .settings
        )
    }

    func testClearedAccountPathOverridesStaleSidebarSelection() {
        let account = ActualAccount(id: "account", name: "Checking", offbudget: false, closed: false)
        XCTAssertEqual(
            AdaptiveRootTransition.selection(for: .sidebar, appTab: .accounts, preserving: .account(account), accountPath: []),
            .accounts
        )
    }

    func testDynamicTypeCanForceCompactRootMode() {
        XCTAssertEqual(
            AdaptiveRootPresentationMode.mode(for: 792, dynamicTypeScale: 1.2),
            .compact
        )
    }

    func testSidebarAccountTitleUsesExistingPrivacyProjection() {
        let account = ActualAccount(id: "account", name: "Private Account Name", offbudget: false, closed: false)
        let destination = AdaptiveRootDestination.account(account)
        XCTAssertEqual(destination.title(privacyEnabled: false), account.name)
        XCTAssertEqual(destination.title(privacyEnabled: true), PrivacyDisplay.name(for: .account, seed: account.id))
        XCTAssertNotEqual(destination.title(privacyEnabled: true), account.name)
        XCTAssertEqual(AdaptiveRootDestination.budget.title(privacyEnabled: true), "Budget")
    }

    func testTransitionSelectionKeepsAccountWhenReturningToSidebar() {
        let account = ActualAccount(id: "account", name: "Checking", offbudget: false, closed: false)
        XCTAssertEqual(
            AdaptiveRootTransition.selection(for: .sidebar, appTab: .accounts, preserving: .account(account), accountPath: [account]),
            .account(account)
        )
        XCTAssertEqual(
            AdaptiveRootTransition.selection(for: .compact, appTab: .accounts, preserving: .account(account)),
            .accounts
        )
    }

}
