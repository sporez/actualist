import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func assignCategoryBudgetLocallyRefreshesBudgetMonth() async throws {
        let store = try await makeOpenedWritableStore()
        var didAssign = false

        let loaded = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {
            didAssign = true
        }

        let groceries = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })
        let reloaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let reloadedGroceries = try #require(reloaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(didAssign)
        #expect(groceries.budgeted == 62_500)
        #expect(groceries.spent == -12_345)
        #expect(groceries.balance == 50_155)
        #expect(loaded.month.totalBudgeted == 62_500)
        #expect(loaded.month.toBudget == -62_500)
        #expect(reloadedGroceries.budgeted == 62_500)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func categoryCarryoverPersistsForwardFromTheSelectedMonth() async throws {
        let store = try await makeOpenedWritableStore()
        var didSetCarryover = false

        let loaded = try await store.setCategoryCarryoverAndRefresh(
            categoryID: "utilities",
            carryover: true,
            budgetID: "group-1",
            startMonth: "2026-07"
        ) {
            didSetCarryover = true
        }

        let julyUtilities = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )
        let august = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-08"
        )
        let augustUtilities = try #require(
            august.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )

        #expect(didSetCarryover)
        #expect(julyUtilities.carryover)
        #expect(augustUtilities.carryover)

        _ = try await store.setCategoryCarryoverAndRefresh(
            categoryID: "utilities",
            carryover: false,
            budgetID: "group-1",
            startMonth: "2026-08"
        ) {}

        let reloadedJuly = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        let reloadedAugust = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-08"
        )
        let reloadedJulyUtilities = try #require(
            reloadedJuly.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )
        let reloadedAugustUtilities = try #require(
            reloadedAugust.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )

        #expect(reloadedJulyUtilities.carryover)
        #expect(!reloadedAugustUtilities.carryover)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func allExpenseCategoryCarryoverIncludesHiddenAndLeavesIncomeUnchanged() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            UPDATE categories SET hidden = 1 WHERE id = 'utilities';
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 1, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO zero_budgets VALUES (202607, 'salary', 0, 0);
            """)
        let july = try await store.setAllExpenseCategoryCarryoverAndRefresh(
            carryover: true,
            budgetID: "group-1",
            startMonth: "2026-07"
        )
        let julyCategories = Dictionary(
            uniqueKeysWithValues: july.month.categoryGroups
                .flatMap(\.categories)
                .map { ($0.id, $0) }
        )

        #expect(julyCategories["groceries"]?.carryover == true)
        #expect(julyCategories["utilities"]?.carryover == true)
        #expect(julyCategories["salary"]?.carryover == false)

        _ = try await store.setAllExpenseCategoryCarryoverAndRefresh(
            carryover: false,
            budgetID: "group-1",
            startMonth: "2026-08"
        )
        let reloadedJuly = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        let august = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-08"
        )
        let julyByID = Dictionary(
            uniqueKeysWithValues: reloadedJuly.month.categoryGroups
                .flatMap(\.categories)
                .map { ($0.id, $0) }
        )
        let augustByID = Dictionary(
            uniqueKeysWithValues: august.month.categoryGroups
                .flatMap(\.categories)
                .map { ($0.id, $0) }
        )

        #expect(julyByID["utilities"]?.carryover == true)
        #expect(augustByID["groceries"]?.carryover == false)
        #expect(augustByID["utilities"]?.carryover == false)
        #expect(augustByID["salary"]?.carryover == false)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func allExpenseCategoryCarryoverUsesTrackingBudgetStorage() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY,
                month INTEGER,
                category TEXT,
                amount INTEGER,
                carryover INTEGER,
                goal INTEGER,
                long_goal INTEGER
            );
            INSERT INTO reflect_budgets VALUES ('202607-groceries', 202607, 'groceries', 50000, 0, NULL, NULL);
            """)

        let loaded = try await store.setAllExpenseCategoryCarryoverAndRefresh(
            carryover: true,
            budgetID: "group-1",
            startMonth: "2026-07"
        )
        let categories = loaded.month.categoryGroups.flatMap(\.categories)
        let database = try #require(store.database)
        let carryoverMessages = try await database.pendingLocalSyncMessages()
            .map(\.message)
            .filter { $0.column == "carryover" }

        #expect(loaded.isTrackingBudget)
        #expect(categories.filter { !$0.isIncome }.allSatisfy { $0.carryover })
        #expect(!carryoverMessages.isEmpty)
        #expect(carryoverMessages.allSatisfy { $0.dataset == "reflect_budgets" })
    }

    @Test func moveMoneyLocallyMovesBudgetBetweenCategories() async throws {
        let store = try await makeOpenedWritableStore()
        var didMove = false

        let loaded = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: "utilities",
                amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {
            didMove = true
        }

        let categories = Dictionary(uniqueKeysWithValues: loaded.month.categoryGroups.flatMap(\.categories).map { ($0.id, $0) })
        let groceries = try #require(categories["groceries"])
        let utilities = try #require(categories["utilities"])

        #expect(didMove)
        #expect(groceries.budgeted == 40_000)
        #expect(groceries.balance == 27_655)
        #expect(utilities.budgeted == 10_000)
        #expect(utilities.balance == 10_000)
        #expect(loaded.month.totalBudgeted == 50_000)
        #expect(loaded.month.toBudget == -50_000)
    }

    @Test func moveMoneyLocallyMovesBudgetBackToToBudget() async throws {
        let store = try await makeOpenedWritableStore()

        let loaded = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: nil,
                amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let groceries = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(groceries.budgeted == 40_000)
        #expect(groceries.balance == 27_655)
        #expect(loaded.month.totalBudgeted == 40_000)
        #expect(loaded.month.toBudget == -40_000)
    }

    @Test func moveMoneyLocallyCoversOverspentCategory() async throws {
        let store = try await makeOpenedWritableStore()
        let overspend = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -10_000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "utilities",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        _ = try await store.createTransactionAndRefresh(overspend, budgetID: "group-1") {}
        let before = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let beforeUtilities = try #require(before.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })

        let loaded = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: "utilities",
                amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let utilities = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })

        #expect(beforeUtilities.balance == -10_000)
        #expect(before.alerts.contains { $0.kind == "overspending" })
        #expect(utilities.budgeted == 10_000)
        #expect(utilities.balance == 0)
        #expect(!loaded.alerts.contains { $0.kind == "overspending" })
    }

    @Test func applyCategoryTemplateSetsFixedSimpleAmount() async throws {
        let store = try await makeOpenedWritableStore()
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .category("utilities"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let utilities = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })
        let database = try #require(store.database)
        let pendingMessages = try await database.pendingLocalSyncMessages().map(\.message)
        let utilityBudgetMessages = pendingMessages.filter {
            $0.dataset == "zero_budgets" && $0.row == "202607-utilities"
        }
        #expect(utilities.budgeted == 30_000)
        #expect(utilityBudgetMessages.map(\.column) == ["month", "category", "amount"])
        #expect(utilityBudgetMessages.map(\.serializedValue) == ["N:202607", "S:utilities", "N:30000"])
    }

    @Test func applyCategoryTemplateSetsPeriodicAmount() async throws {
        let store = try await makeOpenedWritableStore()
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .category("subscriptions"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let subscriptions = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "subscriptions" })
        #expect(subscriptions.budgeted == 4_500)
    }

    @Test func applyCategoryTemplateCopiesPreviousMonthBudget() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "copycat",
            budgeted: 2_500,
            budgetID: "group-1",
            month: "2026-06"
        ) {}
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .category("copycat"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let copycat = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "copycat" })
        #expect(copycat.budgeted == 2_500)
    }

    @Test func applyMonthTemplateFillEmptyOnlyFillsUnbudgetedAndSkipsUnsupported() async throws {
        let store = try await makeOpenedWritableStore()
        // Budgeted categories are skipped, even when their template is unsupported.
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "dining",
            budgeted: 5_000,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .fillEmpty,
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let categories = loaded.month.categoryGroups.flatMap(\.categories)
        let groceries = try #require(categories.first { $0.id == "groceries" })
        let utilities = try #require(categories.first { $0.id == "utilities" })
        let dining = try #require(categories.first { $0.id == "dining" })

        #expect(utilities.budgeted == 30_000)
        #expect(groceries.budgeted == 50_000)
        #expect(dining.budgeted == 5_000)
    }

    @Test func applyMonthTemplateOverwriteRefusesUnsupportedTemplate() async throws {
        let store = try await makeOpenedWritableStore()
        await #expect(throws: LocalFirstError.self) {
            _ = try await store.applyBudgetTemplateAndRefresh(
                command: .overwrite,
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let utilities = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })
        #expect(utilities.budgeted == 0)
    }

    @Test func applyCategoryTemplateRefusesUnsupportedTargetedCategory() async throws {
        let store = try await makeOpenedWritableStore()
        await #expect(throws: LocalFirstError.self) {
            _ = try await store.applyBudgetTemplateAndRefresh(
                command: .category("dining"),
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
    }
}
