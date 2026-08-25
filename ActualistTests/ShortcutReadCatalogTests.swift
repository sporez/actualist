import Foundation
import Testing
@testable import Actualist

@MainActor
struct ShortcutReadCatalogTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession(
        extraSQL: String = ""
    ) async throws -> ShortcutsBudgetSession {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: extraSQL)
        let appState = try fixtures.makeAppState(for: bundle)
        return ShortcutsBudgetSession(appState: appState)
    }

    @Test func readyToAssignMatchesBudgetMonth() async throws {
        let session = try await makeSession()
        let summary = try await session.budgetSummary()
        let loaded = try await session.loadedMonth()

        #expect(summary.month == loaded.selectedMonth)
        #expect(summary.readyToAssign?.amount == Decimal(loaded.month.toBudget) / 100)
        #expect(summary.totalBudgeted?.amount == Decimal(loaded.month.totalBudgeted) / 100)
        #expect(summary.totalSpent?.amount == Decimal(loaded.month.totalSpent) / 100)
    }

    @Test func overspentCategoriesAreVisibleExpenseWithNegativeBalance() async throws {
        let session = try await makeSession(
            extraSQL: "INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES ('over', 'checking', 20260705, -60000, 'utilities', 0, NULL, 0);"
        )
        let overspent = try await session.overspentCategories()
        #expect(overspent.contains { $0.id == "utilities" })
        #expect(overspent.allSatisfy { ($0.isHidden == false) && ($0.isIncome == false) })
        #expect(!overspent.contains { $0.id == "groceries" })
    }

    @Test func uncategorizedCountAndTransactionsUseTheSelectedMonth() async throws {
        let session = try await makeSession(
            extraSQL: "INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES ('uncat', 'checking', 20260704, -500, NULL, 0, NULL, 0);"
        )

        #expect(try await session.uncategorizedCount() == 1)
        let items = try await session.uncategorizedTransactions()
        #expect(items.map(\.id) == ["uncat"])
        #expect(items.first?.category == nil)
    }

    @Test func transactionQueryCapsAtOneHundred() async throws {
        #expect(ShortcutsBudgetSession.cappedTransactionLimit(0) == 1)
        #expect(ShortcutsBudgetSession.cappedTransactionLimit(25) == 25)
        #expect(ShortcutsBudgetSession.cappedTransactionLimit(50) == 50)
        #expect(ShortcutsBudgetSession.cappedTransactionLimit(100) == 100)
        #expect(ShortcutsBudgetSession.cappedTransactionLimit(250) == 100)
    }

    @Test func transactionsIncludePayeeAmountAndRespectSearch() async throws {
        let session = try await makeSession(
            extraSQL: "UPDATE transactions SET description = 'coffee' WHERE id = 'txn';"
        )
        let items = try await session.transactions(accountID: "checking", limit: 25)
        let txn = try #require(items.first { $0.id == "txn" })
        #expect(txn.payee == "Coffee Shop")
        #expect(txn.amount?.amount == Decimal(string: "-123.45"))
        #expect(txn.account == "Checking")
        #expect(txn.category == "Groceries")
        #expect(!txn.isTransfer)

        let matches = try await session.transactions(search: "coffee")
        #expect(matches.contains { $0.id == "txn" })
        #expect(try await session.transaction(id: "txn").id == "txn")
    }

    @Test func accountLookupReturnsBalanceAndMissingAccountFails() async throws {
        let session = try await makeSession()
        let checking = try await session.account(id: "checking")
        #expect(checking.balance?.amount == Decimal(string: "-123.45"))
        await #expect(throws: ShortcutsError.accountNotFound) {
            _ = try await session.account(id: "missing")
        }
    }

    @Test func reportsDashboardReturnsLocalValuesWithoutRequiringAServer() async throws {
        let session = try await makeSession()
        let dashboard = try await session.reportsDashboard()
        #expect(dashboard.netWorth.balance == dashboard.netWorth.points.last?.value ?? dashboard.netWorth.balance)
        #expect(dashboard.cashFlow.month.isEmpty == false)
        #expect(dashboard.budgetOverview.month.isEmpty == false)
    }

    @Test func budgetAlertsSurfaceReadyToAssignWhenPresent() async throws {
        let session = try await makeSession()
        let summary = try await session.budgetSummary()
        let alerts = try await session.budgetAlerts()
        let ready = (try? summary.readyToAssign.map { try ShortcutMoney.minorUnits(from: $0) }) ?? 0
        if ready != 0 {
            #expect(alerts.contains { $0.title == "To Budget" })
        }
    }
}
