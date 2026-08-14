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

    @Test func snapshotOmitsTransferPayeesWithoutAResolvableDisplayName() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            INSERT INTO payees VALUES ('orphaned-transfer', '', 'deleted-account', 0);
            INSERT INTO payee_mapping VALUES ('orphaned-transfer', 'orphaned-transfer');
            INSERT INTO payees VALUES ('legacy-transfer', 'Legacy Account', 'missing-account', 0);
            INSERT INTO payee_mapping VALUES ('legacy-transfer', 'legacy-transfer');
            """)

        try await store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        let snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))

        #expect(!snapshot.payees.contains { $0.id == "orphaned-transfer" })
        #expect(snapshot.payees.first { $0.id == "legacy-transfer" }?.displayName == "Legacy Account")
        #expect(snapshot.payees.first { $0.id == "xfer-checking" }?.displayName == "Checking")
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

        try await store.undoLastPayeeMutationAndRefresh(budgetID: "group-1")
        snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(snapshot.payees.contains { $0.id == created.id && $0.name == "Corner Store" })

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

        try await store.undoLastPayeeMutationAndRefresh(budgetID: "group-1")
        let restored = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(restored.payees.contains { $0.id == "cafe-a" })
        #expect(try await database.fetchTransactions().first { $0.id == "txn" }?.payee == "cafe-a")
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
            INSERT INTO rules VALUES (
                'completed-unused-rule',
                '[{"field":"payee","op":"is","value":"unused"}]',
                '[{"field":"category","op":"set","value":"groceries"}]',
                0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY,
                rule TEXT,
                completed INTEGER,
                tombstone INTEGER
            );
            INSERT INTO schedules VALUES ('completed-schedule', 'completed-unused-rule', 1, 0);
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
        try await store.undoLastPayeeMutationAndRefresh(budgetID: "group-1")
        #expect(store.cachedPayeeManagementSnapshot(budgetID: "group-1")?.payees.contains {
            $0.id == "unused"
        } == true)
        try await store.deletePayeeAndRefresh(budgetID: "group-1", payeeID: "unused")

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

    @Test func favoriteLearningAndUndoUseNativePayeeAndPreferenceFields() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            ALTER TABLE payees ADD COLUMN favorite INTEGER DEFAULT 0;
            ALTER TABLE payees ADD COLUMN learn_categories INTEGER DEFAULT 1;
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('learn-categories', 'true');
            """)

        try await store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        var snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(snapshot.supportsFavorite)
        #expect(snapshot.supportsCategoryLearning)

        try await store.updatePayeesAndRefresh(
            budgetID: "group-1",
            updates: [PayeeManagementUpdate(payeeID: "coffee", favorite: true, learnCategories: false)]
        )
        snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(snapshot.payees.first { $0.id == "coffee" }?.favorite == true)
        #expect(snapshot.payees.first { $0.id == "coffee" }?.learnCategories == false)
        #expect(snapshot.canUndo)

        try await store.undoLastPayeeMutationAndRefresh(budgetID: "group-1")
        snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(snapshot.payees.first { $0.id == "coffee" }?.favorite == false)
        #expect(snapshot.payees.first { $0.id == "coffee" }?.learnCategories == true)
        #expect(!snapshot.canUndo)

        try await store.setGlobalCategoryLearningAndRefresh(budgetID: "group-1", enabled: false)
        snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(!snapshot.globalCategoryLearningEnabled)
    }

    @Test func rulesRoundTripAndPreviewAgainstPayee() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            """)
        let draft = RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [RuleCondition(field: "payee", operation: "is", value: .string("coffee"), type: "id")],
            actions: [
                RuleAction(operation: "set", field: "category", value: .string("groceries"), type: "id"),
                RuleAction(operation: "append-notes", value: .string(" learned"))
            ]
        )

        try await store.createRuleAndRefresh(budgetID: "group-1", draft: draft)
        let rules = try #require(store.cachedRules(budgetID: "group-1"))
        let rule = try #require(rules.first)
        #expect(rule.draft?.stage == .normal)
        #expect(rule.draft?.conditions.first?.value == .string("coffee"))
        #expect(rule.draft?.actions.first?.value == .string("groceries"))
        #expect(rule.payeeIDs == ["coffee"])

        let preview = try await store.previewRules(
            for: TransactionDraft(
                accountID: "checking",
                date: Date(timeIntervalSince1970: 1_783_036_800),
                amountMinorUnits: -500,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: nil,
                notes: "Morning",
                cleared: false,
                isTransfer: false
            ),
            budgetID: "group-1"
        )
        #expect(preview.categoryID == "groceries")
        #expect(preview.notes == "Morning learned")
    }

    @Test func pwaDescriptionOneOfPayeeRuleRemainsEditable() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            INSERT INTO payees VALUES ('market', 'Neighborhood Market', NULL, 0);
            INSERT INTO payee_mapping VALUES ('market', 'market');
            INSERT INTO rules VALUES (
                'pwa-one-of',
                NULL,
                '[{"op":"oneOf","field":"description","value":["coffee","market"],"type":"id"}]',
                '[{"op":"set","field":"category","value":"groceries","type":"id"}]',
                'and',
                0
            );
            """)
        let database = try #require(store.database)

        let rule = try #require(try await database.fetchRules().first { $0.id == "pwa-one-of" })

        #expect(rule.isEditable)
        #expect(rule.draft?.conditions.first?.field == "description")
        #expect(rule.draft?.conditions.first?.editorField == "payee")
        #expect(rule.draft?.conditions.first?.value == .array([.string("coffee"), .string("market")]))
        #expect(rule.payeeIDs == ["coffee", "market"])
    }

    @Test func rulePreviewResolvesMappedPayeesAndKeepsImportedNameDistinct() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            INSERT INTO payees VALUES ('old-coffee', 'Old Coffee', NULL, 1);
            INSERT INTO payee_mapping VALUES ('old-coffee', 'coffee');
            INSERT INTO rules VALUES (
                'mapped-payee',
                NULL,
                '[{"field":"payee","op":"is","value":"old-coffee","type":"id"}]',
                '[{"op":"append-notes","value":" mapped"}]',
                'and',
                0
            );
            INSERT INTO rules VALUES (
                'imported-name',
                NULL,
                '[{"field":"imported_payee","op":"contains","value":"amzn","type":"string"}]',
                '[{"op":"append-notes","value":" imported"}]',
                'and',
                0
            );
            """)
        let database = try #require(store.database)
        let rules = try await database.fetchRules()
        let mappedRule = try #require(rules.first { $0.id == "mapped-payee" })
        #expect(mappedRule.draft?.conditions.first?.value == .string("coffee"))

        let preview = try await store.previewRules(
            for: TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 8, day: 12),
                amountMinorUnits: -500,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: nil,
                notes: "Morning",
                cleared: false,
                isTransfer: false,
                importedPayee: "AMZN Marketplace"
            ),
            budgetID: "group-1"
        )
        #expect(preview.notes == "Morning imported mapped" || preview.notes == "Morning mapped imported")
    }

    @Test func ruleEditorOptionsIncludeClosedHiddenAndIncomeEntities() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            INSERT INTO accounts VALUES ('closed', 'Closed Account', 0, 1, 0, 9);
            INSERT INTO category_groups VALUES ('hidden-group', 'Hidden Group', 0, 1, 0, 9);
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 10);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('hidden-category', 'Hidden Category', 'hidden-group', 0, 1, 0, 9, NULL);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('income-category', 'Income Category', 'income-group', 1, 0, 0, 10, NULL);
            """)

        let options = try await store.ruleEditorOptions(budgetID: "group-1")

        #expect(options.accounts.contains { $0.id == "closed" && $0.name == "Closed Account" })
        #expect(options.categoryGroups.contains { $0.id == "hidden-group" })
        #expect(options.categoryGroups.contains { $0.id == "income-group" })
        #expect(options.categories.contains { $0.id == "hidden-category" })
        #expect(options.categories.contains { $0.id == "income-category" })
        #expect(options.payees.contains { $0.id == "xfer-checking" && $0.isTransfer })
    }

    @Test func ruleEditorPreviewReturnsNewestTransactionsMatchingDraftConditions() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            INSERT INTO payees VALUES ('market', 'Neighborhood Market', NULL, 0);
            INSERT INTO payee_mapping VALUES ('market', 'market');
            UPDATE transactions
            SET description = 'coffee', notes = 'Morning', cleared = 1
            WHERE id = 'txn';
            INSERT INTO transactions (
                id, acct, date, amount, category, tombstone, parent_id, is_parent,
                description, notes, cleared, transferred_id, isChild
            ) VALUES (
                'market-txn', 'credit', 20260805, -4800, 'utilities', 0, NULL, 0,
                'market', 'Internet', 0, NULL, 0
            );
            """)
        var draft = RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [
                RuleCondition(
                    field: "payee",
                    operation: "oneOf",
                    value: .array([.string("coffee"), .string("market")]),
                    type: "id"
                ),
                RuleCondition(
                    field: "category",
                    operation: "is",
                    value: .string("utilities"),
                    type: "id"
                )
            ],
            actions: [RuleAction(operation: "append-notes", value: .string(" matched"))]
        )

        var preview = try await store.matchingTransactions(
            budgetID: "group-1",
            draft: draft,
            limit: 25
        )
        #expect(preview.totalCount == 1)
        #expect(preview.transactions.map(\.id) == ["market-txn"])
        #expect(preview.transactions.first?.payeeName == "Neighborhood Market")
        #expect(preview.transactions.first?.categoryName == "Utilities")
        #expect(preview.transactions.first?.accountName == "Credit Card")
        #expect(preview.transactions.first?.amountMinorUnits == -4800)

        draft.conditionsJoin = .or
        preview = try await store.matchingTransactions(
            budgetID: "group-1",
            draft: draft,
            limit: 1
        )
        #expect(preview.totalCount == 2)
        #expect(preview.transactions.map(\.id) == ["market-txn"])
    }

    @Test func unsupportedRuleShapesStayReadOnlyAndCannotBeRewritten() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            INSERT INTO rules VALUES (
                'unsupported',
                NULL,
                '[{"field":"payee","op":"is","value":"coffee","customName":"Coffee"}]',
                '[{"op":"delete-transaction","value":""}]',
                'and',
                0
            );
            """)
        let database = try #require(store.database)
        let rule = try #require(try await database.fetchRules().first)

        #expect(!rule.isEditable)
        #expect(rule.rawConditionsJSON.contains("customName"))
        #expect(rule.rawActionsJSON.contains("delete-transaction"))

        let unsupportedDraft = RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [RuleCondition(field: "payee", operation: "is", value: .string("coffee"))],
            actions: [RuleAction(operation: "delete-transaction")]
        )
        await #expect(throws: LocalFirstError.self) {
            try await store.createRuleAndRefresh(budgetID: "group-1", draft: unsupportedDraft)
        }
    }

    @Test func categoryLearningMatchesActualThreeOfLatestFiveThreshold() async throws {
        let payeeID = "ABCDEF12-3456-4789-ABCD-EF1234567890"
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            ALTER TABLE payees ADD COLUMN learn_categories INTEGER DEFAULT 1;
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('learn-categories', 'true');
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            INSERT INTO payees VALUES ('ABCDEF12-3456-4789-ABCD-EF1234567890', 'Coffee Shop', NULL, 0, 1);
            INSERT INTO payee_mapping VALUES ('ABCDEF12-3456-4789-ABCD-EF1234567890', 'ABCDEF12-3456-4789-ABCD-EF1234567890');
            UPDATE transactions SET description = 'ABCDEF12-3456-4789-ABCD-EF1234567890' WHERE id = 'txn';
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, notes, cleared, transferred_id, isChild)
                VALUES ('txn-2', 'checking', 20260702, -500, 'groceries', 0, NULL, 0, 'ABCDEF12-3456-4789-ABCD-EF1234567890', NULL, 0, NULL, 0);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, notes, cleared, transferred_id, isChild)
                VALUES ('txn-3', 'checking', 20260701, -700, 'groceries', 0, NULL, 0, 'ABCDEF12-3456-4789-ABCD-EF1234567890', NULL, 0, NULL, 0);
            """)
        let database = try #require(store.database)
        let transaction = try #require(try await database.fetchTransactions().first { $0.id == "txn" })

        _ = try await store.categorizeTransactionAndRefresh(
            transaction,
            categoryID: "groceries",
            budgetID: "group-1",
            didUpdate: {}
        )

        let rules = try await database.fetchRules()
        let learned = try #require(rules.first { $0.payeeIDs.contains(payeeID) })
        #expect(learned.draft?.actions.first?.value == .string("groceries"))

        let preview = try await store.previewRules(
            for: TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 7, day: 3),
                amountMinorUnits: -900,
                payeeID: payeeID,
                payeeName: "Coffee Shop",
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            ),
            budgetID: "group-1"
        )
        #expect(preview.categoryID == "groceries")
    }
}
