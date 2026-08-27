import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func budgetDatabaseMapsAccountsBalancesAndBudgetMonth() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let accounts = try await database.fetchAccountDisplays()
        let months = try await database.fetchAvailableMonths()
        let month = try await database.fetchBudgetMonth(month: "2026-07")

        #expect(accounts.map(\.account.id) == ["checking"])
        #expect(accounts.first?.balance == -12_345)
        #expect(months == ["2026-07"])
        #expect(month.totalBudgeted == 50_000)
        #expect(month.totalSpent == -12_345)
        #expect(month.totalBalance == 37_655)
        #expect(month.categoryGroups.first?.categories.first?.carryover == true)
    }

    @Test func budgetDatabaseMapsLinkedAccountBankSyncStates() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN bank TEXT;
            ALTER TABLE accounts ADD COLUMN account_sync_source TEXT;
            ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT;
            UPDATE accounts
            SET bank = 'simplefin-bank', account_sync_source = 'simpleFin', bank_sync_status = 'ok'
            WHERE id = 'checking';
            INSERT INTO accounts
                (id, name, offbudget, closed, tombstone, sort_order, account_sync_source, bank_sync_status)
            VALUES
                ('attention', 'Needs Attention', 0, 0, 0, 2, 'simpleFin', 'attention-required'),
                ('pending', 'Pending', 0, 0, 0, 3, 'simpleFin', 'sync-requested'),
                ('future-failure', 'Future Failure', 0, 0, 0, 4, 'simpleFin', 'new-provider-error'),
                ('local', 'Local Account', 0, 0, 0, 5, NULL, 'failed');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let accounts = try await database.fetchAccounts()
        let states = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.bankSyncState) })

        #expect(states["checking"] == .healthy)
        #expect(states["attention"] == .failed)
        #expect(states["pending"] == .pending)
        #expect(states["future-failure"] == .failed)
        let localAccount = try #require(accounts.first { $0.id == "local" })
        #expect(localAccount.bankSyncState == nil)
    }

    @Test func cachedBudgetBackfillsAndThenAppliesBankSyncStatusMessages() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN bank TEXT;
            ALTER TABLE accounts ADD COLUMN account_sync_source TEXT;
            UPDATE accounts
            SET bank = 'simplefin-bank', account_sync_source = 'simpleFin'
            WHERE id = 'checking';
            INSERT INTO messages_crdt (timestamp, dataset, row, column, value)
            VALUES (
                '2026-07-01T12:00:00.000Z-0000-remote',
                'accounts',
                'checking',
                'bank_sync_status',
                'S:timed-out'
            );
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        var account = try #require(try await database.fetchAccounts().first)
        #expect(account.bankSyncStatus == "timed-out")
        #expect(account.bankSyncState == .failed)

        let appliedCount = try await database.applyRemoteSyncMessages([
            ActualSyncDecodedMessage(
                timestamp: "2026-07-01T13:00:00.000Z-0000-remote",
                dataset: "accounts",
                row: "checking",
                column: "bank_sync_status",
                serializedValue: "S:ok"
            )
        ])

        #expect(appliedCount == 1)
        account = try #require(try await database.fetchAccounts().first)
        #expect(account.bankSyncStatus == "ok")
        #expect(account.bankSyncState == .healthy)
    }

    @Test func budgetDatabaseCanonicalizesAvailableMonthValues() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO zero_budgets VALUES ('2026-8', 'groceries', 50000, 1);
            INSERT INTO transactions VALUES ('sept', 'checking', '2026/09/03', -12345, 'groceries', 0, NULL, 0);
            INSERT INTO transactions VALUES ('invalid-month', 'checking', '2026-13-03', -12345, 'groceries', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        #expect(try await database.fetchAvailableMonths() == ["2026-07", "2026-08", "2026-09"])
    }

    @Test func budgetTemplateMessagesAppliesPriorityPeriodicWhenAvailable() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-july', 'checking', 20260701, 100000, 'salary', 0, NULL, 0);
            INSERT INTO categories VALUES ('priority-food', 'Food', 'group', 0, 0, 0, 2, '[{"directive":"template","type":"periodic","amount":5,"period":{"period":"month","amount":1},"starting":"2026-07-01","priority":1}]');
            INSERT INTO category_mapping VALUES ('priority-food', 'priority-food');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("priority-food"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let food = try #require(month.categoryGroups.flatMap(\.categories).first { $0.id == "priority-food" })

        #expect(food.budgeted == 500)
    }

    @Test func budgetTemplateMonthlyUpToTopsUpAcrossMonths() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'buffer', 'Buffer', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":50,"limit":{"amount":100,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('buffer', 'buffer');
            INSERT INTO zero_budgets VALUES (202606, 'buffer', 10000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'buffer', 0, 0);
            INSERT INTO transactions VALUES ('buffer-june', 'checking', 20260610, -2000, 'buffer', 0, NULL, 0);
            INSERT INTO transactions VALUES ('buffer-july', 'checking', 20260710, -3000, 'buffer', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let julyMessages = try await database.budgetTemplateMessages(
            command: .category("buffer"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(julyMessages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let julyBuffer = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "buffer" }
        )
        #expect(julyBuffer.budgeted == 2_000)
        #expect(julyBuffer.balance == 7_000)

        let augustMessages = try await database.budgetTemplateMessages(
            command: .category("buffer"),
            month: "2026-08",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(augustMessages)
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let augustBuffer = try #require(
            august.categoryGroups.flatMap(\.categories).first { $0.id == "buffer" }
        )
        #expect(augustBuffer.budgeted == 3_000)
        #expect(augustBuffer.balance == 10_000)
    }

    @Test func budgetTemplateMonthlyUpToCanRefillOrReleaseExcess() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'refill', 'Refill', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":null,"limit":{"amount":100,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('refill', 'refill');
            INSERT INTO zero_budgets VALUES (202606, 'refill', 8000, 0);
            INSERT INTO categories VALUES (
                'release', 'Release', 'group', 0, 0, 0, 3,
                '[{"directive":"template","type":"simple","monthly":50,"limit":{"amount":100,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('release', 'release');
            INSERT INTO zero_budgets VALUES (202606, 'release', 12000, 0);
            INSERT INTO categories VALUES (
                'hold', 'Hold', 'group', 0, 0, 0, 4,
                '[{"directive":"template","type":"simple","monthly":50,"limit":{"amount":100,"period":"monthly","hold":true,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('hold', 'hold');
            INSERT INTO zero_budgets VALUES (202606, 'hold', 12000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let refillMessages = try await database.budgetTemplateMessages(
            command: .category("refill"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(refillMessages)

        let releaseMessages = try await database.budgetTemplateMessages(
            command: .category("release"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(releaseMessages)

        let holdMessages = try await database.budgetTemplateMessages(
            command: .category("hold"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(holdMessages)

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let categories = july.categoryGroups.flatMap(\.categories)
        #expect(categories.first { $0.id == "refill" }?.budgeted == 2_000)
        #expect(categories.first { $0.id == "release" }?.budgeted == -2_000)
        #expect(categories.first { $0.id == "hold" }?.budgeted == 0)
    }

    @Test func budgetTemplatePeriodicEveryTwoWeeksHonorsMonthlyUpTo() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'allowance', 'Allowance', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"periodic","amount":20,"period":{"period":"week","amount":2},"starting":"2026-06-20","limit":{"amount":30,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('allowance', 'allowance');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("allowance"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let allowance = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "allowance" }
        )

        // July 4 and July 18 would total $40, so the monthly up-to caps it at $30.
        #expect(allowance.budgeted == 3_000)
    }

    @Test func budgetTemplateAncientDailyRecurrenceUsesBoundedArithmetic() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"periodic","amount":1,"period":{"period":"day","amount":1},"starting":"0001-01-01","priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let groceries = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 3_100)
    }

    @Test func budgetTemplateRejectsOutOfBoundsInputsBeforeTheyCanPersist() async throws {
        let invalidTemplates = [
            ("amount above maximum", #"{"directive":"template","type":"simple","monthly":1000000001,"priority":0}"#),
            ("negative up-to limit", #"{"directive":"template","type":"simple","monthly":10,"limit":{"amount":-1,"period":"monthly","hold":false,"start":null},"priority":0}"#),
            ("percentage above maximum", #"{"directive":"template","type":"simple","monthly":10,"percentage":101,"priority":0}"#),
            ("period interval above maximum", #"{"directive":"template","type":"periodic","amount":1,"period":{"period":"day","amount":1201},"starting":"2026-07-01","priority":0}"#),
            ("look-back above maximum", #"{"directive":"template","type":"copy","lookBack":1201,"priority":0}"#),
            ("repeat interval above maximum", #"{"directive":"template","type":"by","amount":10,"month":"2026-08","repeat":1201,"priority":0}"#),
            ("priority above maximum", #"{"directive":"template","type":"simple","monthly":10,"priority":1001}"#),
            ("negative remainder weight", #"{"directive":"template","type":"remainder","weight":-1}"#),
            ("missing directive", #"{"type":"simple","monthly":10,"priority":0}"#),
            ("malformed directive", #"{"directive":"nope","type":"simple","monthly":10,"priority":0}"#),
            ("missing remainder weight", #"{"directive":"template","type":"remainder"}"#),
            ("simple null priority", #"{"directive":"template","type":"simple","monthly":10,"priority":null}"#),
            ("periodic null priority", #"{"directive":"template","type":"periodic","amount":1,"period":{"period":"month","amount":1},"starting":"2026-07-01","priority":null}"#),
            ("remainder numeric priority", #"{"directive":"template","type":"remainder","weight":1,"priority":1}"#),
            ("limit numeric priority", #"{"directive":"template","type":"limit","amount":10,"period":"monthly","hold":false,"priority":1}"#),
            ("error directive with simple type", #"{"directive":"error","type":"simple","monthly":10,"priority":0}"#),
            ("template directive with error type", #"{"directive":"template","type":"error"}"#)
        ]

        for (label, template) in invalidTemplates {
            let fixtureURL = try makeSQLiteFixture(extraSQL: """
                ALTER TABLE categories ADD COLUMN goal_def TEXT;
                UPDATE categories
                SET goal_def = '[\(template)]'
                WHERE id = 'groceries';
                """)
            let database = try BudgetDatabase(databaseURL: fixtureURL)
            var builder = LocalFirstSyncMessageBuilder()

            do {
                _ = try await database.budgetTemplateMessages(
                    command: .category("groceries"),
                    month: "2026-07",
                    builder: &builder
                )
                Issue.record("Expected \(label) to be rejected")
            } catch LocalFirstError.unsupportedTemplate {
            } catch {
                Issue.record("Unexpected error for \(label): \(error)")
            }

            let july = try await database.fetchBudgetMonth(month: "2026-07")
            let groceries = try #require(
                july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
            )
            #expect(groceries.budgeted == 50_000, "Invalid case persisted: \(label)")
            #expect(try await database.pendingLocalSyncMessageCount() == 0)
        }
    }

    @Test func budgetTemplateWeeklyUpToCountsWeeksFromTheStartDate() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'weekly', 'Weekly', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":1000,"limit":{"amount":10,"period":"weekly","hold":false,"start":"2026-07-03"},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('weekly', 'weekly');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("weekly"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let weekly = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "weekly" }
        )

        #expect(weekly.budgeted == 5_000)
    }

    @Test func budgetTemplateDailyUpToScalesByDaysInTheMonth() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'daily', 'Daily', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":100,"limit":{"amount":1,"period":"daily","hold":false},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('daily', 'daily');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("daily"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let daily = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "daily" }
        )

        #expect(daily.budgeted == 3_100)
    }

    @Test func budgetTemplateRemainderTakesLeftoverAvailableBudget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-july', 'checking', 20260701, 100000, 'salary', 0, NULL, 0);
            INSERT INTO categories VALUES (
                'leftover', 'Leftover', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"remainder","weight":1}]'
            );
            INSERT INTO category_mapping VALUES ('leftover', 'leftover');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("leftover"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let leftover = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "leftover" }
        )

        #expect(leftover.budgeted == 50_000)
    }

    @Test func budgetTemplateApplySingleClampsPriorityTemplatesToAvailableBudget() async throws {
        let later = try await appliedLaterPriorityTemplate(command: .category("later"))
        #expect(later == 50_000)
    }

    @Test func budgetTemplateWholeMonthStillClampsPriorityTemplates() async throws {
        let later = try await appliedLaterPriorityTemplate(command: .overwrite)
        #expect(later == 50_000)
    }

    @Test func budgetTemplateSamePriorityFundsFollowBudgetOrderNotCategoryID() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-july', 'checking', 20260701, 100000, 'salary', 0, NULL, 0);
            INSERT INTO categories VALUES (
                'z-first', 'First', 'group', 0, 0, 0, 10,
                '[{"directive":"template","type":"simple","monthly":1000,"priority":1}]'
            );
            INSERT INTO category_mapping VALUES ('z-first', 'z-first');
            INSERT INTO categories VALUES (
                'a-second', 'Second', 'group', 0, 0, 0, 20,
                '[{"directive":"template","type":"simple","monthly":1000,"priority":1}]'
            );
            INSERT INTO category_mapping VALUES ('a-second', 'a-second');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let categories = Dictionary(
            uniqueKeysWithValues: july.categoryGroups.flatMap(\.categories).map { ($0.id, $0.budgeted) }
        )

        #expect(categories["z-first"] == 50_000)
        #expect(categories["a-second"] == 0)
        #expect("a-second" < "z-first")
    }

    private func appliedLaterPriorityTemplate(command: BudgetTemplateCommand) async throws -> Int {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-july', 'checking', 20260701, 100000, 'salary', 0, NULL, 0);
            INSERT INTO categories VALUES (
                'later', 'Later', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":1000,"priority":1}]'
            );
            INSERT INTO category_mapping VALUES ('later', 'later');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: command,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        return try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "later" }?.budgeted
        )
    }

    @Test func budgetTemplateStandaloneMonthlyLimitAndRefillTopsUp() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'buffer', 'Buffer', 'group', 0, 0, 0, 2,
                '[
                    {"directive":"template","type":"limit","amount":100,"period":"monthly","hold":false,"start":null,"priority":null},
                    {"directive":"template","type":"refill","priority":0}
                ]'
            );
            INSERT INTO category_mapping VALUES ('buffer', 'buffer');
            INSERT INTO zero_budgets VALUES (202606, 'buffer', 8000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("buffer"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let buffer = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "buffer" }
        )

        #expect(buffer.budgeted == 2_000)
        #expect(buffer.balance == 10_000)
    }

    @Test func budgetTemplateBySpreadsRemainingTargetAcrossMonths() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'insurance', 'Insurance', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"by","amount":120,"month":"2026-09","priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('insurance', 'insurance');
            INSERT INTO zero_budgets VALUES (202606, 'insurance', 3000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let julyMessages = try await database.budgetTemplateMessages(
            command: .category("insurance"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(julyMessages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let julyInsurance = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "insurance" }
        )
        #expect(julyInsurance.budgeted == 3_000)
        #expect(julyInsurance.balance == 6_000)

        let augustMessages = try await database.budgetTemplateMessages(
            command: .category("insurance"),
            month: "2026-08",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(augustMessages)
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let augustInsurance = try #require(
            august.categoryGroups.flatMap(\.categories).first { $0.id == "insurance" }
        )
        #expect(augustInsurance.budgeted == 3_000)
        #expect(augustInsurance.balance == 9_000)
    }

    @Test func budgetTemplateByAdvancesAnAnnualTarget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'renewal', 'Annual Renewal', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"by","amount":120,"month":"2026-06","annual":true,"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('renewal', 'renewal');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("renewal"),
            month: "2026-08",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let renewal = try #require(
            august.categoryGroups.flatMap(\.categories).first { $0.id == "renewal" }
        )

        // The next June is 10 months away, so Actual spreads $120 over 11 months.
        #expect(renewal.budgeted == 1_091)
    }

    @Test func budgetTemplateDecodeFailureNamesCategoryAndFieldWithoutWriting() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"periodic","amount":50,"period":"month","priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected the malformed periodic template to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Groceries"))
            #expect(reason.contains("template[0].period"))
            #expect(reason.localizedCaseInsensitiveContains("string"))
        }

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let groceries = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 50_000)
    }

    @Test func budgetTemplateIncomeCategoryIsNotClampedByAvailableBudget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES (
                'salary', 'Salary', 'income-group', 1, 0, 0, 0,
                '[{"directive":"template","type":"simple","monthly":100,"priority":1}]'
            );
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("salary"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let salary = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "salary" }
        )

        #expect(salary.budgeted == 10_000)
        #expect(messages.contains { message in
            message.dataset == "zero_budgets" && message.row.contains("salary")
        })
    }

    @Test func budgetTemplateErrorOnlyGoalDefWritesNothing() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"error","type":"error","line":"#template bad","error":"parse failure"}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )

        #expect(messages.isEmpty)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let groceries = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 50_000)
    }

    @Test func budgetTemplateIgnoresErrorEntriesAndAppliesValidSiblings() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[
                {"directive":"error","type":"error","line":"#template bad","error":"parse failure"},
                {"directive":"template","type":"simple","monthly":50,"priority":0}
            ]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let groceries = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )

        #expect(groceries.budgeted == 5_000)
    }

    @Test func budgetTemplateWholeBudgetSkipsOrphanedAndHiddenGroupCategories() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":10,"priority":0}]'
            WHERE id = 'groceries';
            INSERT INTO categories VALUES (
                'orphan', 'Orphan', 'missing-group', 0, 0, 0, 50,
                '[{"directive":"template","type":"simple","monthly":25,"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('orphan', 'orphan');
            INSERT INTO category_groups VALUES ('hidden-group', 'Hidden', 0, 1, 0, 2);
            INSERT INTO categories VALUES (
                'hidden-cat', 'Hidden Cat', 'hidden-group', 0, 0, 0, 1,
                '[{"directive":"template","type":"simple","monthly":40,"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('hidden-cat', 'hidden-cat');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let wholeBudget = try await database.budgetTemplateMessages(
            command: .overwrite,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(wholeBudget)

        #expect(try zeroBudgetAmount("groceries", at: fixtureURL) == 1_000)
        #expect(try zeroBudgetAmount("orphan", at: fixtureURL) == nil)
        #expect(try zeroBudgetAmount("hidden-cat", at: fixtureURL) == nil)

        let orphanMessages = try await database.budgetTemplateMessages(
            command: .category("orphan"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(orphanMessages)
        #expect(try zeroBudgetAmount("orphan", at: fixtureURL) == 2_500)

        let hiddenMessages = try await database.budgetTemplateMessages(
            command: .category("hidden-cat"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(hiddenMessages)
        #expect(try zeroBudgetAmount("hidden-cat", at: fixtureURL) == 4_000)
    }

    @Test func toBudgetIsCumulativeAcrossMonthsNotJustCurrentMonth() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO zero_budgets VALUES (202606, 'groceries', 50000, 1);
            INSERT INTO transactions VALUES ('inc-jun', 'checking', 20260615, 200000, 'salary', 0, NULL, 0);
            INSERT INTO transactions VALUES ('gro-jun', 'checking', 20260620, -40000, 'groceries', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try await database.fetchBudgetMonth(month: "2026-07")

        // Income 200000 - total budgeted 100000.
        #expect(month.toBudget == 100_000)
    }

    @Test func toBudgetIgnoresUncategorizedActivityUntilCategorized() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('income', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
            INSERT INTO transactions VALUES ('mystery', 'checking', 20260705, -1000, NULL, 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try await database.fetchBudgetMonth(month: "2026-07")

        #expect(month.toBudget == 150_000)
    }

    @Test func budgetDatabaseUsesActualiSpendingSemanticsForMappedSplits() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            UPDATE zero_budgets SET amount = 0, carryover = 0 WHERE month = 202607 AND category = 'groceries';
            INSERT INTO category_mapping VALUES ('old-groceries', 'groceries');
            INSERT INTO zero_budgets VALUES (202608, 'groceries', 50000, 0);
            INSERT INTO transactions VALUES ('mapped', 'checking', 20260803, -10000, 'old-groceries', 0, NULL, 0);
            INSERT INTO transactions VALUES ('split-parent', 'checking', 20260804, -30000, 'groceries', 0, NULL, 1);
            INSERT INTO transactions VALUES ('split-child-1', 'checking', 20260804, -20000, 'groceries', 0, 'split-parent', 0);
            INSERT INTO transactions VALUES ('split-child-2', 'checking', 20260804, -10000, 'groceries', 0, 'split-parent', 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let month = try await database.fetchBudgetMonth(month: "2026-08")
        let groceries = month.categoryGroups.first?.categories.first

        #expect(groceries?.budgeted == 50_000)
        #expect(groceries?.spent == -40_000)
        #expect(groceries?.balance == 10_000)
    }

    @Test func manualHoldForNextMonthReducesToBudgetAndReturnsNextMonth() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('inc-jul', 'checking', 20260710, 100000, 'salary', 0, NULL, 0);
            INSERT INTO zero_budget_months VALUES ('2026-07', 25000);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let august = try await database.fetchBudgetMonth(month: "2026-08")

        // Balance 87655 - leftover 37655 - hold 25000. The hold returns in August.
        #expect(july.toBudget == 25_000)
        #expect(july.forNextMonth == 25_000)
        #expect(august.toBudget == 50_000)
        #expect(august.forNextMonth == 0)
    }

    @Test func carryoverIncomeCategoryInfersHoldForNextMonth() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO zero_budgets VALUES (202607, 'salary', 0, 1);
            INSERT INTO transactions VALUES ('inc-jul', 'checking', 20260710, 40000, 'salary', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let august = try await database.fetchBudgetMonth(month: "2026-08")

        // July's income into the carryover-flagged income category is held for next month.
        #expect(july.toBudget == -50_000)
        #expect(july.forNextMonth == 40_000)
        // Without a flagged row in August the hold returns.
        #expect(august.toBudget == -10_000)
        #expect(august.forNextMonth == 0)
    }

    @Test func explicitHoldOverridesInferredIncomeCarryoverHold() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER);
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO zero_budgets VALUES (202607, 'salary', 0, 1);
            INSERT INTO transactions VALUES ('inc-jul', 'checking', 20260710, 40000, 'salary', 0, NULL, 0);
            INSERT INTO zero_budget_months VALUES ('2026-07', 20000);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try await database.fetchBudgetMonth(month: "2026-07")

        // The explicit 20000 hold wins; the inferred 40000 does not stack.
        #expect(month.toBudget == -30_000)
        #expect(month.forNextMonth == 20_000)
    }

    @Test func expenseCategoryCarryoverDoesNotInferHoldWhenHoldTableIsMissing() async throws {
        // Base fixture: groceries budgeted 50000 with carryover, 12345 spent — an expense
        // category carryover must never infer a hold, and legacy databases without
        // zero_budget_months must still query cleanly.
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try await database.fetchBudgetMonth(month: "2026-07")

        #expect(month.toBudget == -50_000)
        #expect(month.forNextMonth == 0)
    }

    @Test func totalBudgetedMatchesExpenseGroupAssignedAndChangesWithMonth() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('goals', 'Goals', 0, 0, 0, 2);
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 3);
            INSERT INTO category_groups VALUES ('hidden-grp', 'Hidden Group', 0, 1, 0, 4);
            INSERT INTO categories VALUES ('dining', 'Dining', 'group', 0, 0, 0, 2);
            INSERT INTO categories VALUES ('hidden-cat', 'Hidden Cat', 'group', 0, 1, 0, 3);
            INSERT INTO categories VALUES ('vacation', 'Vacation', 'goals', 0, 0, 0, 1);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 1);
            INSERT INTO categories VALUES ('deleted', 'Deleted', 'group', 0, 0, 1, 4);
            INSERT INTO categories VALUES ('secret', 'Secret', 'hidden-grp', 0, 0, 0, 1);
            INSERT INTO zero_budgets VALUES (202607, 'dining', 10000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'hidden-cat', 5000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'vacation', 20000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'salary', 99999, 0);
            INSERT INTO zero_budgets VALUES (202607, 'deleted', 88888, 0);
            INSERT INTO zero_budgets VALUES (202607, 'secret', 4000, 0);
            INSERT INTO zero_budgets VALUES (202608, 'groceries', 30000, 0);
            INSERT INTO zero_budgets VALUES (202608, 'dining', 2000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let julyExpenseAssigned = july.categoryGroups
            .filter { !$0.isIncome }
            .reduce(0) { $0 + $1.budgeted }
        let julyIncomeAssigned = july.categoryGroups
            .filter(\.isIncome)
            .reduce(0) { $0 + $1.budgeted }
        let everydayAssigned = try #require(
            july.categoryGroups.first { $0.id == "group" }?.budgeted
        )

        #expect(everydayAssigned == 65_000)
        #expect(julyIncomeAssigned == 99_999)
        #expect(july.totalBudgeted == 89_000)
        #expect(july.totalBudgeted == julyExpenseAssigned)
        #expect(august.totalBudgeted == 32_000)
        #expect(august.totalBudgeted != july.totalBudgeted)
    }

    private func zeroBudgetAmount(_ categoryID: String, at databaseURL: URL) throws -> Int? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT amount
                    FROM zero_budgets
                    WHERE category = ? AND month = 202607
                    """,
                arguments: [categoryID]
            )
        }
    }

}
