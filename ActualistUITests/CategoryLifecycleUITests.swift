import XCTest

@MainActor
final class CategoryLifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompactCreateAndReorderChrome() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact native window") }
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        attachScreenshot(named: "category-lifecycle-compact-budget")

        let group = app.buttons["budget-group-essentials"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reorder"].exists)
        XCTAssertTrue(app.buttons["budget-group-delete-essentials"].exists)
        app.buttons["Rename"].tap()
        let renameSheet = app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 5))
        assertMediumSheet(renameSheet, in: app)
        attachScreenshot(named: "category-lifecycle-compact-rename")
        app.buttons["Cancel"].tap()

        app.buttons["Budget Actions"].tap()
        let categoriesMenu = app.buttons["Categories & Groups"]
        XCTAssertTrue(categoriesMenu.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["History"].exists)
        XCTAssertTrue(app.buttons["Notes"].exists)
        XCTAssertTrue(app.buttons["Templates"].exists)
        attachScreenshot(named: "category-lifecycle-compact-actions-root")

        categoriesMenu.tap()
        XCTAssertTrue(app.buttons["budget-new-category"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-new-group"].exists)
        XCTAssertTrue(app.buttons["Show Hidden Categories"].exists)
        attachScreenshot(named: "category-lifecycle-compact-actions-categories")
        app.buttons["budget-new-category"].tap()
        let createSheet = app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
        XCTAssertTrue(createSheet.waitForExistence(timeout: 5))
        assertMediumSheet(createSheet, in: app)
        XCTAssertTrue(app.textFields["budget-category-lifecycle-name"].exists)
        XCTAssertTrue(app.buttons["budget-category-lifecycle-group"].exists)
        attachScreenshot(named: "category-lifecycle-compact-create")
        app.buttons["Cancel"].tap()

        let category = app.buttons["budget-category-rent"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-rename-rent"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-category-reorder-rent"].exists)
        XCTAssertTrue(app.buttons["budget-category-delete-rent"].exists)
        app.buttons["budget-category-reorder-rent"].tap()
        let reorderSheet = app.descendants(matching: .any)["budget-category-reorder-sheet"]
        XCTAssertTrue(reorderSheet.waitForExistence(timeout: 5))
        assertLargeSheet(reorderSheet, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-category-rent"].exists)
        XCTAssertTrue(app.buttons["budget-category-reorder-save"].exists)
        attachScreenshot(named: "category-lifecycle-compact-reorder")
        app.buttons["budget-category-reorder-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForNonExistence(timeout: 5))

        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-reorder-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-reorder-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-delete-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-delete-rent"].tap()
        let deleteSheet = app.descendants(matching: .any)["budget-category-delete-sheet"]
        XCTAssertTrue(deleteSheet.waitForExistence(timeout: 5))
        assertMediumSheet(deleteSheet, in: app)
        XCTAssertTrue(app.buttons["budget-category-delete-destination"].exists)
        XCTAssertFalse(app.buttons["budget-category-delete-confirm"].isEnabled)
        attachScreenshot(named: "category-lifecycle-compact-delete")
        app.buttons["Cancel"].tap()
    }

    func testCompactReordersCategoryGroupsAndPersistsTheirOrder() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact native window") }
        XCTAssertTrue(app.buttons["budget-category-rent"].waitForExistence(timeout: 15))

        app.buttons["budget-category-rent"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-reorder-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-reorder-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))

        let essentials = app.images["budget-category-reorder-group-essentials"]
        let lifestyle = app.images["budget-category-reorder-group-lifestyle"]
        XCTAssertTrue(essentials.waitForExistence(timeout: 3))
        XCTAssertTrue(lifestyle.exists)
        XCTAssertGreaterThan(lifestyle.frame.minY, essentials.frame.minY)

        lifestyle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 1,
                thenDragTo: essentials.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            )
        let reorderedGroupHandles = app.images.matching(
            NSPredicate(format: "identifier BEGINSWITH 'budget-category-reorder-group-'")
        )
        XCTAssertEqual(
            reorderedGroupHandles.element(boundBy: 0).identifier,
            "budget-category-reorder-group-lifestyle"
        )
        attachScreenshot(named: "category-lifecycle-compact-group-reordered")

        app.buttons["budget-category-reorder-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForNonExistence(timeout: 5))

        let lifestyleGroup = app.buttons["budget-group-lifestyle"]
        XCTAssertTrue(lifestyleGroup.waitForExistence(timeout: 5))
        lifestyleGroup.tap()
        let essentialsGroup = app.buttons["budget-group-essentials"]
        XCTAssertTrue(essentialsGroup.waitForExistence(timeout: 5))
        XCTAssertLessThan(lifestyleGroup.frame.minY, essentialsGroup.frame.minY)

        lifestyleGroup.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-group-reorder-lifestyle"].waitForExistence(timeout: 3))
        app.buttons["budget-group-reorder-lifestyle"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))
        let groupHandles = app.images.matching(
            NSPredicate(format: "identifier BEGINSWITH 'budget-category-reorder-group-'")
        )
        XCTAssertEqual(
            groupHandles.element(boundBy: 0).identifier,
            "budget-category-reorder-group-lifestyle"
        )
    }

    func testCompactReordersCategoriesAndPersistsTheirOrder() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact native window") }
        XCTAssertTrue(app.buttons["budget-category-rent"].waitForExistence(timeout: 15))

        app.buttons["budget-category-rent"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-reorder-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-reorder-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))

        let rent = app.images["budget-category-reorder-category-rent"]
        let groceries = app.images["budget-category-reorder-category-groceries"]
        let utilities = app.images["budget-category-reorder-category-utilities"]
        XCTAssertTrue(rent.waitForExistence(timeout: 3))
        XCTAssertTrue(groceries.exists)
        XCTAssertTrue(utilities.exists)
        XCTAssertGreaterThan(groceries.frame.minY, rent.frame.minY)

        groceries.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 1,
                thenDragTo: rent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            )
        let reorderedCategoryHandles = app.images.matching(
            NSPredicate(format: "identifier BEGINSWITH 'budget-category-reorder-category-'")
        )
        XCTAssertEqual(
            reorderedCategoryHandles.element(boundBy: 0).identifier,
            "budget-category-reorder-category-groceries"
        )
        attachScreenshot(named: "category-lifecycle-compact-category-reordered")

        groceries.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 1,
                thenDragTo: utilities.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            )
        XCTAssertEqual(
            reorderedCategoryHandles.element(boundBy: 0).identifier,
            "budget-category-reorder-category-rent"
        )
        XCTAssertEqual(
            reorderedCategoryHandles.element(boundBy: 1).identifier,
            "budget-category-reorder-category-utilities"
        )
        XCTAssertEqual(
            reorderedCategoryHandles.element(boundBy: 2).identifier,
            "budget-category-reorder-category-groceries"
        )
        attachScreenshot(named: "category-lifecycle-compact-category-reordered-twice")

        app.buttons["budget-category-reorder-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForNonExistence(timeout: 5))

        let groceriesCategory = app.buttons["budget-category-groceries"]
        let rentCategory = app.buttons["budget-category-rent"]
        let utilitiesCategory = app.buttons["budget-category-utilities"]
        XCTAssertTrue(groceriesCategory.waitForExistence(timeout: 5))
        XCTAssertTrue(rentCategory.exists)
        XCTAssertTrue(utilitiesCategory.exists)
        XCTAssertLessThan(rentCategory.frame.minY, utilitiesCategory.frame.minY)
        XCTAssertLessThan(utilitiesCategory.frame.minY, groceriesCategory.frame.minY)

        groceriesCategory.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-reorder-groceries"].waitForExistence(timeout: 3))
        app.buttons["budget-category-reorder-groceries"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))
        let categoryHandles = app.images.matching(
            NSPredicate(format: "identifier BEGINSWITH 'budget-category-reorder-category-'")
        )
        XCTAssertEqual(
            categoryHandles.element(boundBy: 0).identifier,
            "budget-category-reorder-category-rent"
        )
        XCTAssertEqual(
            categoryHandles.element(boundBy: 1).identifier,
            "budget-category-reorder-category-utilities"
        )
        XCTAssertEqual(
            categoryHandles.element(boundBy: 2).identifier,
            "budget-category-reorder-category-groceries"
        )
    }

    func testCompactBudgetActionsExposeTemplateSubmenu() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchDemo()
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact native window") }
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))

        app.buttons["Budget Actions"].tap()
        XCTAssertTrue(app.buttons["Templates"].waitForExistence(timeout: 3))
        app.buttons["Templates"].tap()
        XCTAssertTrue(app.buttons["Apply Template"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Apply Template Overwrite"].exists)
        attachScreenshot(named: "category-lifecycle-compact-actions-templates")
    }

    func testCompactCategorySheetsUseLightPalette() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launchDemo(screen: "settings/appearance")
        guard app.frame.width < 792 else { throw XCTSkip("Requires a compact native window") }
        selectTheme("Actual Purple (light)", in: app)
        app.terminate()

        app = launchDemo(replaceDemo: false)
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 15))
        app.buttons["Budget Actions"].tap()
        app.buttons["Categories & Groups"].tap()
        XCTAssertTrue(app.buttons["budget-new-category"].waitForExistence(timeout: 3))
        app.buttons["budget-new-category"].tap()
        let createSheet = app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
        XCTAssertTrue(createSheet.waitForExistence(timeout: 5))
        assertMediumSheet(createSheet, in: app)
        attachScreenshot(named: "category-lifecycle-light-create")
        app.buttons["Cancel"].tap()

        let category = app.buttons["budget-category-rent"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-reorder-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-reorder-rent"].tap()
        let reorderSheet = app.descendants(matching: .any)["budget-category-reorder-sheet"]
        XCTAssertTrue(reorderSheet.waitForExistence(timeout: 5))
        assertLargeSheet(reorderSheet, in: app)
        attachScreenshot(named: "category-lifecycle-light-reorder")
        app.buttons["Cancel"].tap()

        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-category-delete-rent"].waitForExistence(timeout: 3))
        app.buttons["budget-category-delete-rent"].tap()
        let deleteSheet = app.descendants(matching: .any)["budget-category-delete-sheet"]
        XCTAssertTrue(deleteSheet.waitForExistence(timeout: 5))
        assertMediumSheet(deleteSheet, in: app)
        attachScreenshot(named: "category-lifecycle-light-delete")
        app.buttons["Cancel"].tap()
        app.terminate()

        app = launchDemo(screen: "settings/appearance", replaceDemo: false)
        selectTheme("Actual Purple (dark)", in: app)
    }

    func testWideCreateRenameAndReorderChrome() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchDemo()
        guard app.frame.width >= 792 else { throw XCTSkip("Requires a wide native window") }
        XCTAssertTrue(app.descendants(matching: .any)["budget-grid"].waitForExistence(timeout: 15))

        let group = app.buttons["budget-grid-group-essentials"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        group.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reorder"].exists)
        XCTAssertTrue(app.buttons["budget-grid-group-delete-essentials"].exists)
        app.buttons["Rename"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
            .waitForExistence(timeout: 5))
        attachScreenshot(named: "category-lifecycle-wide-rename")
        app.buttons["Cancel"].tap()

        app.buttons["Budget Actions"].tap()
        XCTAssertTrue(app.buttons["budget-new-category"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-new-group"].exists)
        app.buttons["budget-new-group"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-lifecycle-name-sheet"]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        let category = app.buttons["budget-grid-category-rent"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.press(forDuration: 1)
        XCTAssertTrue(app.buttons["budget-grid-category-rename-rent"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["budget-grid-category-reorder-rent"].exists)
        XCTAssertTrue(app.buttons["budget-grid-category-delete-rent"].exists)
        attachScreenshot(named: "category-lifecycle-wide-delete-menu")
        app.buttons["budget-grid-category-reorder-rent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-sheet"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["budget-category-reorder-category-rent"].exists)
        attachScreenshot(named: "category-lifecycle-wide-reorder")
        app.buttons["Cancel"].tap()
    }

    func testSampleValuesHideCategoryLifecycleActions() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launchDemo()
        let isWide = app.frame.width >= 792
        app.terminate()

        app = launchDemo(screen: "settings/privacy", replaceDemo: false)
        let sampleValues = app.switches["Use Sample Values"]
        XCTAssertTrue(sampleValues.waitForExistence(timeout: 5))
        if sampleValues.value as? String == "0" {
            sampleValues.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(sampleValues.value as? String, "1")
        app.terminate()

        app = launchDemo(replaceDemo: false)
        XCTAssertTrue(app.buttons["Budget Actions"].waitForExistence(timeout: 10))
        app.buttons["Budget Actions"].tap()
        if !isWide {
            app.buttons["Categories & Groups"].tap()
        }
        XCTAssertFalse(app.buttons["budget-new-category"].exists)
        XCTAssertFalse(app.buttons["budget-new-group"].exists)
        app.tap()

        let group = app.buttons[isWide ? "budget-grid-group-essentials" : "budget-group-essentials"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Notes"].waitForExistence(timeout: 3))
        let prefix = isWide ? "budget-grid-group" : "budget-group"
        XCTAssertFalse(app.buttons["\(prefix)-rename-essentials"].exists)
        XCTAssertFalse(app.buttons["\(prefix)-reorder-essentials"].exists)
        XCTAssertFalse(app.buttons["\(prefix)-delete-essentials"].exists)
        app.terminate()

        app = launchDemo(screen: "settings/privacy", replaceDemo: false)
        let restore = app.switches["Use Sample Values"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        if restore.value as? String == "1" {
            restore.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(restore.value as? String, "0")
    }

    private func launchDemo(
        screen: String = "budget",
        replaceDemo: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sporez.actualist")
        app.launchArguments = ["-actualist-demo", "-actualist-screen", screen]
        if replaceDemo {
            app.launchArguments.append("-actualist-replace-demo-for-ui-testing")
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func selectTheme(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 10))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Theme'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
        app.buttons[title].tap()
    }

    private func assertMediumSheet(
        _ sheet: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(
            sheet.frame.minY,
            app.frame.height * 0.3,
            "Expected a medium-height sheet, got \(sheet.frame)",
            file: file,
            line: line
        )
    }

    private func assertLargeSheet(
        _ sheet: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThan(
            sheet.frame.minY,
            app.frame.height * 0.3,
            "Expected a large sheet, got \(sheet.frame)",
            file: file,
            line: line
        )
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
