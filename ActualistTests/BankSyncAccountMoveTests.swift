import Foundation
import GRDB
import Testing
@testable import Actualist

/// Rule `set account` is not silently applied on Bank Sync. Matching still
/// happens against the linked source account; an unsupported destination is a
/// blocking review problem.
@MainActor
struct BankSyncAccountMoveTests {
    private let support = LocalFirstActualStoreTests()
    private func accountMoveSQL() -> String {
        """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER
        );
        INSERT INTO rules VALUES (
            'move-account',
            '[{"field":"imported_payee","op":"is","value":"Coffee Shop","type":"string"}]',
            '[{"field":"account","op":"set","value":"checking","type":"id"}]',
            0
        );
        """
    }

    private func linkedAccountMoveStore(
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let remote = support.remoteAccount(balance: "0.00")
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    remote.accountID: SimpleFINAccountDownload(
                        transactions: [
                            support.remoteTransaction(
                                id: "move-1",
                                amount: "-10.00",
                                dayID: "20260302",
                                payeeName: "Coffee Shop"
                            ),
                            support.remoteTransaction(
                                id: "keep-1",
                                amount: "20.00",
                                dayID: "20260302",
                                payeeName: "Employer"
                            )
                        ],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await support.makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: additionalFixtureSQL
        )
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")
        return bundle
    }

    @Test func ruleAccountChangeIsABlockingProblemAndDoesNotWrite() async throws {
        let bundle = try await linkedAccountMoveStore(additionalFixtureSQL: accountMoveSQL())
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.problems == [.unsupportedAccountMove(remoteTransactionID: "move-1")])
        #expect(plan.inserts.map(\.financialID) == ["keep-1"])
        #expect(!plan.inserts.contains { $0.financialID == "move-1" })
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        let imported = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM transactions
                    WHERE financial_id IN ('move-1', 'keep-1')
                      AND IFNULL(tombstone, 0) = 0
                    """
            )
        }
        #expect(imported == 0)
        let summary = BankSyncCopy.problemSummary(plan.problems)
        #expect(summary?.contains("another account") == true)
    }

    @Test func backgroundBankSyncRejectsAccountMoveBeforeAnyWrite() async throws {
        let bundle = try await linkedAccountMoveStore(additionalFixtureSQL: accountMoveSQL())
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        }
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        let imported = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM transactions
                    WHERE financial_id IN ('move-1', 'keep-1')
                      AND IFNULL(tombstone, 0) = 0
                    """
            )
        }
        #expect(imported == 0)
    }

    @Test func ruleThatLeavesAccountUnchangedStillInserts() async throws {
        let bundle = try await linkedAccountMoveStore(
            additionalFixtureSQL: """
                CREATE TABLE rules (
                    id TEXT PRIMARY KEY,
                    conditions TEXT,
                    actions TEXT,
                    tombstone INTEGER
                );
                INSERT INTO rules VALUES (
                    'set-category',
                    '[{"field":"imported_payee","op":"is","value":"Coffee Shop","type":"string"}]',
                    '[{"field":"category","op":"set","value":"groceries","type":"id"}]',
                    0
                );
                """
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.problems.isEmpty)
        #expect(Set(plan.inserts.compactMap(\.financialID)) == ["move-1", "keep-1"])
        #expect(plan.inserts.first { $0.financialID == "move-1" }?.categoryID == "groceries")
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        let imported = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM transactions
                    WHERE financial_id IN ('move-1', 'keep-1')
                      AND IFNULL(tombstone, 0) = 0
                    """
            )
        }
        #expect(imported == 2)
    }
}
