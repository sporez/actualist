import Foundation
import Testing
@testable import Actualist

@MainActor
struct ShortcutTransactionCommandTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession(
        defaultAccountID: String? = nil,
        extraSQL: String = ""
    ) async throws -> (session: ShortcutsBudgetSession, appState: AppState) {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: extraSQL)
        let appState = try fixtures.makeAppState(for: bundle)
        if let defaultAccountID {
            appState.settings.defaultAccountIDByBudgetID["group-1"] = defaultAccountID
        }
        return (ShortcutsBudgetSession(appState: appState), appState)
    }

    private func makeSplitSession() async throws -> ShortcutsBudgetSession {
        let (session, _) = try await makeSession(
            extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                VALUES ('split-parent', 'checking', 20260710, -5000, NULL, 0, NULL, 1);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                VALUES ('split-a', 'checking', 20260710, -2000, 'groceries', 0, 'split-parent', 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                VALUES ('split-b', 'checking', 20260710, -3000, 'utilities', 0, 'split-parent', 0);
            """
        )
        return session
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

    @Test func omittedCategoryAppliesMatchingPayeeRule() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'cafe-rule',
                '[{"field":"payee_name","op":"is","value":"Rule Cafe"}]',
                '[{"field":"category","op":"set","value":"groceries"}]',
                0
            );
            """
        )
        let appState = try fixtures.makeAppState(for: bundle)
        let session = ShortcutsBudgetSession(appState: appState)
        let transaction = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 800,
                direction: .spend,
                accountID: "checking",
                payeeName: "Rule Cafe",
                cleared: false
            ),
            session: session
        )
        #expect(transaction.category == "Groceries")
    }

    @Test func logRejectsClosedAccounts() async throws {
        let (session, _) = try await makeSession(
            extraSQL: "INSERT INTO accounts VALUES ('closed', 'Old Card', 0, 1, 0, 9);"
        )
        await #expect(throws: ShortcutsError.accountClosed) {
            _ = try await ShortcutTransactionCommand.log(
                .init(
                    amountMinorUnits: 500,
                    direction: .spend,
                    accountID: "closed",
                    payeeName: "Nope",
                    cleared: false
                ),
                session: session
            )
        }
    }

    @Test func transactionLookupFindsRowsOutsideTheRecentPage() async throws {
        var inserts = ["INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES ('old-txn', 'checking', 20200101, -111, 'groceries', 0, NULL, 0);"]
        for index in 0..<110 {
            inserts.append(
                "INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES ('page-\(index)', 'checking', 20260715, -100, 'groceries', 0, NULL, 0);"
            )
        }
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: inserts.joined(separator: "\n")
        )
        let session = ShortcutsBudgetSession(appState: try fixtures.makeAppState(for: bundle))
        let entity = try await session.transaction(id: "old-txn")
        #expect(entity.id == "old-txn")
        let resolved = try await session.transactions(ids: ["old-txn", "missing"])
        #expect(resolved.map(\.id) == ["old-txn"])
    }

    @Test func splitParentNotesAndClearedPreserveChildren() async throws {
        let session = try await makeSplitSession()
        let updated = try await ShortcutTransactionCommand.update(
            .init(transactionID: "split-parent", notes: "Kept split"),
            session: session
        )
        #expect(updated.notes == "Kept split")
        #expect(try await session.actualTransaction(id: "split-a").parentID == "split-parent")
        #expect(try await session.actualTransaction(id: "split-b").parentID == "split-parent")

        let cleared = try await ShortcutTransactionCommand.setCleared(
            transactionID: "split-parent",
            cleared: true,
            session: session
        )
        #expect(cleared.cleared)
        #expect(try await session.actualTransaction(id: "split-a").id == "split-a")
        #expect(try await session.actualTransaction(id: "split-b").id == "split-b")
    }

    @Test func splitStructureChangesFailInsteadOfCorrupting() async throws {
        let session = try await makeSplitSession()

        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: "split-parent", amountMinorUnits: 9_000),
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: "split-a", notes: "child"),
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.setCleared(
                transactionID: "split-b",
                cleared: true,
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.categorize(
                transactionID: "split-parent",
                categoryID: "groceries",
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.delete(
                transactionID: "split-a",
                session: session
            )
        }

        #expect(try await session.actualTransaction(id: "split-parent").isParent)
        #expect(try await session.actualTransaction(id: "split-a").amount == -2_000)
        #expect(try await session.actualTransaction(id: "split-b").amount == -3_000)
    }

    @Test func splitParentWithOneChildPreservesThatChild() async throws {
        let (session, _) = try await makeSession(
            extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, notes, description)
                VALUES ('one-parent', 'checking', 20260711, -3000, NULL, 0, NULL, 1, 0, NULL, NULL);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, notes, description)
                VALUES ('one-child', 'checking', 20260711, -3000, 'groceries', 0, 'one-parent', 0, 1, 'keep-me', 'coffee');
            """
        )
        let updated = try await ShortcutTransactionCommand.update(
            .init(transactionID: "one-parent", notes: "parent note"),
            session: session
        )
        let child = try await session.actualTransaction(id: "one-child")
        #expect(updated.notes == "parent note")
        #expect(child.parentID == "one-parent")
        #expect(child.category == "groceries")
        #expect(child.notes == "keep-me")
        #expect(child.payee == "coffee")
        #expect(child.amount == -3_000)
    }

    @Test func categorizingSplitChildDoesNotFlattenTheFamily() async throws {
        let session = try await makeSplitSession()
        let updated = try await ShortcutTransactionCommand.categorize(
            transactionID: "split-a",
            categoryID: "utilities",
            session: session
        )
        let child = try await session.actualTransaction(id: "split-a")
        let sibling = try await session.actualTransaction(id: "split-b")
        let parent = try await session.actualTransaction(id: "split-parent")
        #expect(updated.id == "split-a")
        #expect(child.category == "utilities")
        #expect(child.isChild)
        #expect(child.parentID == "split-parent")
        #expect(sibling.category == "utilities")
        #expect(sibling.isChild)
        #expect(sibling.amount == -3_000)
        #expect(parent.isParent)
        #expect(parent.subtransactions.count == 2)
    }

    @Test func logAppliesImportedSplitRuleFamily() async throws {
        let (session, _) = try await makeSession(
            extraSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'shortcut-split-rule',
                '[{"op":"is","field":"description","value":"coffee"}]',
                '[{"op":"set-split-amount","value":4000,"options":{"method":"fixed-amount","splitIndex":1}},{"op":"set","field":"category","value":"groceries","options":{"splitIndex":1}},{"op":"set-split-amount","value":0,"options":{"method":"remainder","splitIndex":2}},{"op":"set","field":"category","value":"utilities","options":{"splitIndex":2}}]',
                0
            );
            """
        )
        let transaction = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 10_000,
                direction: .spend,
                accountID: "checking",
                payeeID: "coffee",
                payeeName: "Coffee Shop"
            ),
            session: session
        )
        let parent = try await session.actualTransaction(id: transaction.id)
        #expect(parent.isParent)
        #expect(parent.subtransactions.map { $0.amount ?? 0 } == [4_000, -14_000])
        #expect(parent.subtransactions.map(\.category) == ["groceries", "utilities"])
    }

    @Test func deletingSplitParentRemovesTheWholeSplit() async throws {
        let session = try await makeSplitSession()
        _ = try await ShortcutTransactionCommand.delete(transactionID: "split-parent", session: session)
        await #expect(throws: ShortcutsError.transactionNotFound) {
            _ = try await session.actualTransaction(id: "split-parent")
        }
        await #expect(throws: ShortcutsError.transactionNotFound) {
            _ = try await session.actualTransaction(id: "split-a")
        }
        await #expect(throws: ShortcutsError.transactionNotFound) {
            _ = try await session.actualTransaction(id: "split-b")
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
