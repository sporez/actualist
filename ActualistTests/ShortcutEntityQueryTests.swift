import Foundation
import Testing
@testable import Actualist

@MainActor
struct ShortcutEntityQueryTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession(
        extraSQL: String = ""
    ) async throws -> (session: ShortcutsBudgetSession, bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: extraSQL)
        let appState = try fixtures.makeAppState(for: bundle)
        return (ShortcutsBudgetSession(appState: appState), bundle)
    }

    @Test func accountsHideClosedByDefaultAndKeepOffBudget() async throws {
        let (session, _) = try await makeSession(
            extraSQL: "INSERT INTO accounts VALUES ('closed', 'Old Card', 0, 1, 0, 9);"
        )

        let visible = try await session.accounts(includeClosed: false)
        #expect(visible.map(\.id).sorted() == ["checking", "credit", "savings", "tracking"])
        #expect(visible.contains { $0.id == "tracking" && $0.offBudget })
        #expect(!visible.contains { $0.closed })

        let includingClosed = try await session.accounts(includeClosed: true)
        #expect(includingClosed.contains { $0.id == "closed" && $0.closed })
    }

    @Test func accountEntitiesIncludeBalances() async throws {
        let (session, _) = try await makeSession()
        let checking = try #require(
            try await session.accounts(includeClosed: false).first { $0.id == "checking" }
        )

        #expect(checking.balance?.amount == Decimal(string: "-123.45"))
        #expect(checking.balance?.currencyCode == ShortcutMoney.currencyCode)
        #expect(!checking.offBudget)
    }

    @Test func accountSearchMatchesNameCaseInsensitively() async throws {
        let (session, _) = try await makeSession()
        let matches = try await session.accounts(includeClosed: false, matching: "CHECK")
        #expect(matches.map(\.id) == ["checking"])
        #expect(try await session.accounts(includeClosed: false, matching: "zzz").isEmpty)
    }

    @Test func categoriesHideHiddenAndIncomeByDefault() async throws {
        let (session, _) = try await makeSession(
            extraSQL: """
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('hidden-cat', 'Hidden Stuff', 'group', 0, 1, 0, 9, NULL);
            INSERT INTO category_mapping VALUES ('hidden-cat', 'hidden-cat');
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO zero_budgets VALUES (202607, 'hidden-cat', 0, 0);
            INSERT INTO zero_budgets VALUES (202607, 'salary', 0, 0);
            """
        )

        let visible = try await session.categories(includeHidden: false)
        #expect(!visible.contains { $0.id == "hidden-cat" })
        #expect(!visible.contains { $0.isIncome })
        #expect(visible.contains { $0.id == "groceries" })

        let groceries = try #require(visible.first { $0.id == "groceries" })
        #expect(groceries.group == "Everyday")
        #expect(groceries.carryover)
        #expect(groceries.budgeted?.amount == Decimal(500))

        let includingHidden = try await session.categories(includeHidden: true)
        #expect(includingHidden.contains { $0.id == "hidden-cat" && $0.isHidden })

        let includingIncome = try await session.categories(includeHidden: false, includeIncome: true)
        #expect(includingIncome.contains { $0.id == "salary" && $0.isIncome })
    }

    @Test func categoriesHideChildrenOfHiddenGroupsByDefault() async throws {
        let (session, _) = try await makeSession(
            extraSQL: """
            INSERT INTO category_groups VALUES ('hidden-grp', 'Hidden Group', 0, 1, 0, 4);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('secret', 'Secret', 'hidden-grp', 0, 0, 0, 1, NULL);
            INSERT INTO category_mapping VALUES ('secret', 'secret');
            INSERT INTO zero_budgets VALUES (202607, 'secret', 0, 0);
            """
        )

        let visible = try await session.categories(includeHidden: false)
        #expect(!visible.contains { $0.id == "secret" })

        let includingHidden = try await session.categories(includeHidden: true)
        #expect(includingHidden.contains { $0.id == "secret" && $0.isHidden })
    }

    @Test func categorySearchMatchesVisibleNames() async throws {
        let (session, _) = try await makeSession()
        let matches = try await session.categories(includeHidden: false, matching: "groc")
        #expect(matches.map(\.id) == ["groceries"])
    }

    @Test func payeesHideTransfersByDefault() async throws {
        let (session, _) = try await makeSession()

        let visible = try await session.payees(includeTransfers: false)
        #expect(visible.map(\.id) == ["coffee"])
        #expect(visible.first?.name == "Coffee Shop")
        #expect(visible.allSatisfy { !$0.isTransfer })

        let includingTransfers = try await session.payees(includeTransfers: true)
        #expect(includingTransfers.contains { $0.isTransfer })
        #expect(includingTransfers.contains { $0.id == "coffee" })
    }

    @Test func payeeSearchMatchesDisplayName() async throws {
        let (session, _) = try await makeSession()
        let matches = try await session.payees(includeTransfers: false, matching: "coffee")
        #expect(matches.map(\.id) == ["coffee"])
    }

    @Test func transactionEntitiesResolveByIDOutsideTheSuggestedPage() async throws {
        var inserts = ["INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES ('buried', 'checking', 20200102, -222, 'groceries', 0, NULL, 0);"]
        for index in 0..<110 {
            inserts.append(
                "INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES ('recent-\(index)', 'checking', 20260716, -100, 'groceries', 0, NULL, 0);"
            )
        }
        let (session, _) = try await makeSession(extraSQL: inserts.joined(separator: "\n"))
        let matches = try await session.transactions(ids: ["buried"])
        #expect(matches.map(\.id) == ["buried"])
    }

    @Test func monthsUseCachedBudgetMonthAndFormatDisplayNames() async throws {
        let (session, _) = try await makeSession()
        let months = try await session.months()
        #expect(months.contains { $0.id == "2026-07" })
        let july = try #require(months.first { $0.id == "2026-07" })
        #expect(july.name == ReportCalendar.shortMonthTitle("2026-07"))

        let matches = try await session.months(matching: "2026-07")
        #expect(matches.map(\.id) == ["2026-07"])
    }
}
