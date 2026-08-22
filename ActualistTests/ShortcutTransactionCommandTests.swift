import Foundation
import Testing
@testable import Actualist

@MainActor
struct ShortcutTransactionCommandTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession(
        defaultAccountID: String? = nil
    ) async throws -> (session: ShortcutsBudgetSession, appState: AppState) {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        if let defaultAccountID {
            appState.settings.defaultAccountIDByBudgetID["group-1"] = defaultAccountID
        }
        return (ShortcutsBudgetSession(appState: appState), appState)
    }

    @Test func logSpendUsesNegativeAmountAndPayeeName() async throws {
        let (session, appState) = try await makeSession()
        let before = appState.localDataRevision
        let transaction = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 1_250,
                direction: .spend,
                accountID: "checking",
                payeeName: "Cafe",
                categoryID: "groceries",
                cleared: false
            ),
            session: session
        )
        #expect(transaction.payee == "Cafe")
        #expect(transaction.amount?.amount == Decimal(string: "-12.50"))
        #expect(transaction.category == "Groceries")
        #expect(!transaction.cleared)
        #expect(appState.localDataRevision == before + 1)
    }

    @Test func logInflowUsesPositiveAmount() async throws {
        let (session, _) = try await makeSession()
        let transaction = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 20_000,
                direction: .inflow,
                accountID: "checking",
                payeeName: "Paycheck",
                cleared: false
            ),
            session: session
        )
        #expect(transaction.amount?.amount == Decimal(200))
    }

    @Test func logUsesDefaultAccountAndFailsWhenMissing() async throws {
        let (session, _) = try await makeSession(defaultAccountID: "checking")
        let transaction = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 500,
                direction: .spend,
                payeeName: "Snack",
                cleared: false
            ),
            session: session
        )
        #expect(transaction.account == "Checking")

        let (bareSession, _) = try await makeSession()
        await #expect(throws: ShortcutsError.defaultAccountMissing) {
            _ = try await ShortcutTransactionCommand.log(
                .init(amountMinorUnits: 500, direction: .spend, payeeName: "Snack", cleared: false),
                session: bareSession
            )
        }
    }

    @Test func transferMovesBetweenAccounts() async throws {
        let (session, _) = try await makeSession()
        let transaction = try await ShortcutTransactionCommand.transfer(
            fromAccountID: "checking",
            toAccountID: "savings",
            amountMinorUnits: 5_000,
            date: nil,
            notes: nil,
            session: session
        )
        #expect(transaction.isTransfer)
        #expect(transaction.account == "Checking")
        #expect(transaction.amount?.amount == Decimal(string: "-50"))
    }

    @Test func omittedCategoryStillLogs() async throws {
        let (session, _) = try await makeSession()
        let transaction = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 800,
                direction: .spend,
                accountID: "checking",
                payeeName: "Mystery",
                cleared: false
            ),
            session: session
        )
        #expect(transaction.category == nil)
    }

    @Test func updateAndCategorizeAndDeleteApplyImmediately() async throws {
        let (session, _) = try await makeSession()
        let created = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 900,
                direction: .spend,
                accountID: "checking",
                payeeName: "Shop",
                cleared: false
            ),
            session: session
        )

        let updated = try await ShortcutTransactionCommand.update(
            .init(transactionID: created.id, notes: "Updated note"),
            session: session
        )
        #expect(updated.notes == "Updated note")

        let categorized = try await ShortcutTransactionCommand.categorize(
            transactionID: created.id,
            categoryID: "groceries",
            session: session
        )
        #expect(categorized.category == "Groceries")

        let cleared = try await ShortcutTransactionCommand.setCleared(
            transactionID: created.id,
            cleared: true,
            session: session
        )
        #expect(cleared.cleared)

        let deleted = try await ShortcutTransactionCommand.delete(
            transactionID: created.id,
            session: session
        )
        #expect(deleted.payee == "Shop")
        await #expect(throws: ShortcutsError.transactionNotFound) {
            _ = try await session.transaction(id: created.id)
        }
    }

    @Test func uniqueMatchAllowsPrefixAndRejectsAmbiguity() throws {
        struct Named { let name: String }
        let items = [Named(name: "Checking"), Named(name: "Savings"), Named(name: "Check Card")]
        let savings = try ShortcutTransactionCommand.uniqueMatch(
            in: items,
            named: \.name,
            query: "sav",
            notFound: .accountNotFound
        )
        #expect(savings.name == "Savings")
        #expect(throws: ShortcutsError.ambiguousMatch) {
            _ = try ShortcutTransactionCommand.uniqueMatch(
                in: items,
                named: \.name,
                query: "check",
                notFound: .accountNotFound
            )
        }
    }

    @Test func importFromTextLogsSpend() async throws {
        let (session, _) = try await makeSession(defaultAccountID: "checking")
        let transaction = try await ShortcutTransactionCommand.importFromText(
            "$12.50 coffee",
            session: session
        )
        #expect(transaction.payee == "coffee")
        #expect(transaction.amount?.amount == Decimal(string: "-12.50"))
        #expect(transaction.account == "Checking")
    }
}
