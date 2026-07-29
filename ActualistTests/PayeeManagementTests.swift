import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func snapshotReportsMappedTransactionUsageRulesAndTransfers() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'coffee-rule',
                '[{"field":"description","op":"is","value":"coffee"}]',
                '[{"field":"category","op":"set","value":"groceries"}]',
                0
            );
            UPDATE transactions SET description = 'coffee' WHERE id = 'txn';
            """)

        try await store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        let snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        let coffee = try #require(snapshot.payees.first { $0.id == "coffee" })
        let transfer = try #require(snapshot.payees.first { $0.id == "xfer-checking" })

        #expect(coffee.transactionCount == 1)
        #expect(coffee.ruleReferenceCount == 1)
        #expect(!coffee.canDelete)
        #expect(transfer.isTransfer)
        #expect(transfer.displayName == "Checking")
        #expect(!transfer.canDelete)
        #expect(snapshot.supportsCreate)
        #expect(snapshot.supportsRename)
        #expect(snapshot.supportsMerge)
        #expect(snapshot.supportsDelete)
    }

    @Test func snapshotDisablesMergeWhenPayeeMappingIsUnavailable() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            CREATE TABLE payees (
                id TEXT PRIMARY KEY,
                name TEXT,
                tombstone INTEGER
            );
            INSERT INTO payees VALUES ('coffee', 'Coffee Shop', 0);
            UPDATE transactions SET description = 'coffee' WHERE id = 'txn';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let snapshot = try await database.fetchPayeeManagementSnapshot()
        let coffee = try #require(snapshot.payees.first { $0.id == "coffee" })

        #expect(coffee.transactionCount == 1)
        #expect(snapshot.supportsCreate)
        #expect(snapshot.supportsRename)
        #expect(!snapshot.supportsMerge)
        #expect(snapshot.supportsDelete)
    }

    @Test func createAndRenamePayeeWriteThroughOutboxAndRejectDuplicates() async throws {
        let store = try await makeOpenedWritableStore()

        try await store.createPayeeAndRefresh(budgetID: "group-1", name: "  Corner Store  ")
        var snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        let created = try #require(snapshot.payees.first { $0.name == "Corner Store" })

        try await store.renamePayeeAndRefresh(
            budgetID: "group-1",
            payeeID: created.id,
            name: "Neighborhood Market"
        )
        snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))

        #expect(snapshot.payees.contains { $0.id == created.id && $0.name == "Neighborhood Market" })
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") >= 4)

        await #expect(throws: LocalFirstError.self) {
            try await store.createPayeeAndRefresh(budgetID: "group-1", name: "coffee shop")
        }
        await #expect(throws: LocalFirstError.self) {
            try await store.renamePayeeAndRefresh(
                budgetID: "group-1",
                payeeID: created.id,
                name: "Coffee Shop"
            )
        }
    }

    @Test func mergeRedirectsMappingsTombstonesSourcesAndDoesNotRewriteTransactions() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            INSERT INTO payees VALUES ('cafe-a', 'Cafe A', NULL, 0);
            INSERT INTO payees VALUES ('cafe-b', 'Cafe B', NULL, 0);
            INSERT INTO payee_mapping VALUES ('cafe-a', 'cafe-a');
            INSERT INTO payee_mapping VALUES ('cafe-b', 'cafe-b');
            UPDATE transactions SET description = 'cafe-a' WHERE id = 'txn';
            """)
        let database = try #require(store.database)

        try await store.mergePayeesAndRefresh(
            budgetID: "group-1",
            sourcePayeeIDs: ["cafe-a"],
            targetPayeeID: "cafe-b"
        )

        let snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        let target = try #require(snapshot.payees.first { $0.id == "cafe-b" })
        let transactions = try await database.fetchTransactions()
        let pending = try await database.pendingLocalSyncMessages().map(\.message)

        #expect(!snapshot.payees.contains { $0.id == "cafe-a" })
        #expect(target.transactionCount == 1)
        #expect(transactions.first { $0.id == "txn" }?.payee == "cafe-b")
        #expect(pending.contains {
            $0.dataset == "payee_mapping"
                && $0.row == "cafe-a"
                && $0.column == "targetId"
                && $0.serializedValue == "S:cafe-b"
        })
        #expect(!pending.contains { $0.dataset == "transactions" })
    }

    @Test func deleteAllowsOnlyUnusedUnreferencedPayees() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO payees VALUES ('unused', 'Unused', NULL, 0);
            INSERT INTO payee_mapping VALUES ('unused', 'unused');
            INSERT INTO payees VALUES ('ruled', 'Ruled', NULL, 0);
            INSERT INTO payee_mapping VALUES ('ruled', 'ruled');
            INSERT INTO rules VALUES (
                'ruled-rule',
                '[{"field":"payee","op":"is","value":"ruled"}]',
                '[]',
                0
            );
            UPDATE transactions SET description = 'coffee' WHERE id = 'txn';
            """)

        try await store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        let initial = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(initial.payees.first { $0.id == "unused" }?.canDelete == true)
        #expect(initial.payees.first { $0.id == "coffee" }?.canDelete == false)
        #expect(initial.payees.first { $0.id == "ruled" }?.canDelete == false)

        try await store.deletePayeeAndRefresh(budgetID: "group-1", payeeID: "unused")
        #expect(store.cachedPayeeManagementSnapshot(budgetID: "group-1")?.payees.contains {
            $0.id == "unused"
        } == false)

        await #expect(throws: LocalFirstError.self) {
            try await store.deletePayeeAndRefresh(budgetID: "group-1", payeeID: "coffee")
        }
        await #expect(throws: LocalFirstError.self) {
            try await store.deletePayeeAndRefresh(budgetID: "group-1", payeeID: "ruled")
        }
    }

    @Test func malformedRuleJSONConservativelyBlocksDeletion() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO payees VALUES ('unused', 'Unused', NULL, 0);
            INSERT INTO payee_mapping VALUES ('unused', 'unused');
            INSERT INTO rules VALUES ('broken', '{', '[]', 0);
            """)

        try await store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        let snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))

        #expect(snapshot.hasUnreadableRuleReferences)
        #expect(snapshot.payees.first { $0.id == "unused" }?.canDelete == false)
        await #expect(throws: LocalFirstError.self) {
            try await store.deletePayeeAndRefresh(budgetID: "group-1", payeeID: "unused")
        }
    }

    @Test func viewModelSearchAndSelectionStayWithinRegularPayees() {
        let model = PayeesViewModel()
        model.snapshot = PayeeManagementSnapshot(
            payees: [
                ManagedPayee(
                    id: "coffee",
                    name: "Coffee Shop",
                    transferAccountID: nil,
                    transferAccountName: nil,
                    transactionCount: 2,
                    ruleReferenceCount: 0,
                    canDelete: false
                ),
                ManagedPayee(
                    id: "market",
                    name: "Market",
                    transferAccountID: nil,
                    transferAccountName: nil,
                    transactionCount: 0,
                    ruleReferenceCount: 0,
                    canDelete: true
                ),
                ManagedPayee(
                    id: "transfer",
                    name: "",
                    transferAccountID: "checking",
                    transferAccountName: "Checking",
                    transactionCount: 0,
                    ruleReferenceCount: 0,
                    canDelete: false
                )
            ],
            supportsCreate: true,
            supportsRename: true,
            supportsMerge: true,
            supportsDelete: true,
            hasUnreadableRuleReferences: false
        )

        model.searchText = "cof"
        #expect(model.regularPayees.map(\.id) == ["coffee"])
        #expect(model.transferPayees.isEmpty)

        model.searchText = ""
        model.beginSelection()
        model.toggleSelection("coffee")
        model.toggleSelection("market")
        #expect(model.canBeginMerge)
        #expect(model.selectedPayees.map(\.id).sorted() == ["coffee", "market"])
        model.endSelection()
        #expect(!model.isSelecting)
        #expect(model.selectedPayeeIDs.isEmpty)
    }
}
