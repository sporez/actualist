import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleReadTests {
    private let support = LocalFirstActualStoreTests()

    @Test func reviewUsesInlineBalanceAndProjectsGraphEligibilityLinksAndSchedules() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            ALTER TABLE accounts ADD COLUMN account_id TEXT;
            ALTER TABLE accounts ADD COLUMN account_sync_source TEXT;
            ALTER TABLE accounts ADD COLUMN bank TEXT;
            ALTER TABLE accounts ADD COLUMN balance_current INTEGER;
            ALTER TABLE accounts ADD COLUMN balance_available INTEGER;
            ALTER TABLE accounts ADD COLUMN balance_limit INTEGER;
            ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT;
            UPDATE accounts SET account_id = 'remote-checking', account_sync_source = 'simpleFin', bank = 'bank-row'
                WHERE id = 'checking';
            INSERT INTO accounts (id, name, offbudget, closed, tombstone, sort_order)
                VALUES ('tracking', 'Tracking', 1, 0, 0, 2);
            INSERT INTO accounts (id, name, offbudget, closed, tombstone, sort_order)
                VALUES ('closed', 'Closed', 0, 1, 0, 3);
            INSERT INTO accounts (id, name, offbudget, closed, tombstone, sort_order)
                VALUES ('deleted', 'Deleted', 0, 0, 1, 4);
            INSERT INTO categories VALUES ('hidden-expense', 'Hidden Expense', 'group', 0, 1, 0, 2);
            INSERT INTO categories VALUES ('income', 'Income', 'group', 1, 0, 0, 3);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild)
                VALUES ('split', 'checking', 20260901, -3000, NULL, 0, NULL, 1, 0);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild)
                VALUES ('split-a', 'checking', 20260901, -1000, 'groceries', 0, 'split', 0, 1);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild)
                VALUES ('split-b', 'checking', 20260901, -2000, 'groceries', 0, 'split', 0, 1);
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, transferred_id)
                VALUES ('source-transfer', 'checking', 20260902, 5000, NULL, 0, NULL, 0, 0, 'paired-transfer');
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, transferred_id)
                VALUES ('paired-transfer', 'tracking', 20260902, -5000, NULL, 0, NULL, 0, 0, 'source-transfer');
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY, name TEXT, rule TEXT, completed INTEGER, tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'rent-rule',
                '[{"field":"acct","op":"is","value":"checking"}]',
                '[{"op":"link-schedule","value":"rent"}]',
                0
            );
            INSERT INTO schedules VALUES ('rent', 'Rent', 'rent-rule', 0, 0);
            """))
        let request = AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: "tracking", categoryID: "groceries")
        )

        let review = try await database.accountLifecycleReview(
            request: request,
            localDay: testDay
        )

        #expect(review.liveBalance == -10_345)
        #expect(review.liveTransactionCount == 5)
        #expect(review.liveFamilyCount == 3)
        #expect(review.pairedTransferCount == 1)
        #expect(review.eligibleDestinations.map(\.id) == ["tracking"])
        #expect(review.eligibleCategories.map(\.id) == ["groceries", "hidden-expense"])
        #expect(review.bankLink?.provider == .simpleFIN)
        #expect(review.activeScheduleReferences == [AccountScheduleReference(id: "rent", name: "Rent")])
        #expect(review.blockers.isEmpty)
        #expect(review.resolvedAction == .closeWithTransfer(AccountClosingTransfer(
            destinationAccountID: "tracking",
            sourceAmount: 10_345,
            destinationAmount: -10_345,
            categoryID: "groceries",
            date: "2026-09-27",
            notes: "Closing account"
        )))
    }

    @Test func eligibilityIncludesOnlyLiveOpenAccounts() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('closed', 'Closed', 0, 1, 0, 2);
            INSERT INTO accounts VALUES ('deleted', 'Deleted', 0, 0, 1, 3);
            """))

        let snapshot = try await database.accountEligibilitySnapshot()

        #expect(snapshot.eligiblePostingAccounts.map(\.id) == ["checking"])
        if case .closed(let account) = snapshot.postingEligibility(accountID: "closed") {
            #expect(account.name == "Closed")
        } else {
            Issue.record("Expected explicit closed-account eligibility")
        }
        #expect(snapshot.postingEligibility(accountID: "deleted") == .missing(accountID: "deleted"))
    }

    @Test func reviewFailsClosedWhenTransferIdentitySchemaIsMissing() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture())
        let request = AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )

        await #expect(throws: AccountLifecycleCommandError.missingTransactionSchema) {
            try await database.accountLifecycleReview(request: request)
        }
    }

    @Test func reviewBlocksWhenScheduleTablesCannotBeInspectedTogether() async throws {
        for partialSchema in [
            "CREATE TABLE schedules (id TEXT PRIMARY KEY, name TEXT, rule TEXT);",
            "CREATE TABLE rules (id TEXT PRIMARY KEY, conditions TEXT, actions TEXT);",
        ] {
            let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
                ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
                \(partialSchema)
                """))

            let review = try await database.accountLifecycleReview(
                request: closeRequest,
                localDay: testDay
            )

            #expect(review.blockers.contains(.scheduleInspectionUnavailable))
            #expect(review.resolvedAction == nil)
        }
    }

    @Test func malformedAndDetachedScheduleGraphsFailClosedWithoutOmittingDigestFacts() async throws {
        for graphSQL in [
            """
            INSERT INTO rules VALUES ('broken', '[', '[]', 0);
            INSERT INTO schedules VALUES ('schedule', 'Broken', 'broken', 0, 0);
            """,
            """
            INSERT INTO schedules VALUES ('schedule', 'Detached', 'missing-rule', 0, 0);
            """,
        ] {
            let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
                ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
                CREATE TABLE rules (
                    id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER
                );
                CREATE TABLE schedules (
                    id TEXT PRIMARY KEY, name TEXT, rule TEXT, completed INTEGER, tombstone INTEGER
                );
                \(graphSQL)
                """))
            let review = try await database.accountLifecycleReview(
                request: closeRequest,
                localDay: testDay
            )
            #expect(review.blockers.contains(.scheduleInspectionUnavailable))
            #expect(review.resolvedAction == nil)
            #expect(!review.identity.scheduleDigest.isEmpty)
        }
    }

    @Test func bothPinnedAccountFieldAliasesProduceScheduleReferencesWithoutBlockingClose() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            UPDATE transactions SET amount = 0 WHERE id = 'txn';
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY, name TEXT, rule TEXT, completed INTEGER, tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'acct-rule', '[{"field":"acct","op":"is","value":"checking"}]',
                '[{"op":"link-schedule","value":"acct-schedule"}]', 0
            );
            INSERT INTO rules VALUES (
                'account-rule', '[{"field":"account","op":"is","value":"checking"}]',
                '[{"op":"link-schedule","value":"account-schedule"}]', 0
            );
            INSERT INTO schedules VALUES ('acct-schedule', 'Acct', 'acct-rule', 0, 0);
            INSERT INTO schedules VALUES ('account-schedule', 'Account', 'account-rule', 0, 0);
            """))

        let review = try await database.accountLifecycleReview(
            request: closeRequest,
            localDay: testDay
        )

        #expect(review.activeScheduleReferences.map(\.id) == ["account-schedule", "acct-schedule"])
        #expect(review.blockers.isEmpty)
        #expect(review.resolvedAction == .closeAtZero)
    }

    @Test func everyLinkedProviderExceptVerifiedSimpleFINBlocksOrdinaryClose() async throws {
        for (source, expectedProvider) in [
            ("goCardless", AccountLifecycleBankProvider.goCardless),
            ("pluggyAI", .pluggyAI),
            ("akahu", .akahu),
            ("enableBanking", .enableBanking),
            ("future-provider", .unknown),
        ] {
            let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
                ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
                ALTER TABLE accounts ADD COLUMN account_id TEXT;
                ALTER TABLE accounts ADD COLUMN account_sync_source TEXT;
                ALTER TABLE accounts ADD COLUMN bank TEXT;
                ALTER TABLE accounts ADD COLUMN balance_current INTEGER;
                ALTER TABLE accounts ADD COLUMN balance_available INTEGER;
                ALTER TABLE accounts ADD COLUMN balance_limit INTEGER;
                ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT;
                UPDATE accounts SET account_id = 'remote', account_sync_source = '\(source)', bank = 'bank'
                    WHERE id = 'checking';
                """))
            let review = try await database.accountLifecycleReview(
                request: closeRequest,
                localDay: testDay
            )
            #expect(review.blockers.contains(.unsupportedBankProvider(expectedProvider)))
            #expect(review.resolvedAction == nil)
        }

        let ambiguous = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            ALTER TABLE accounts ADD COLUMN account_id TEXT;
            ALTER TABLE accounts ADD COLUMN account_sync_source TEXT;
            UPDATE accounts SET account_sync_source = 'simpleFin' WHERE id = 'checking';
            """))
        let review = try await ambiguous.accountLifecycleReview(request: closeRequest, localDay: testDay)
        #expect(review.blockers.contains(.unsupportedBankProvider(.unknown)))
    }

    @Test func onlyOnBudgetToOffBudgetRequiresAndCarriesCategory() async throws {
        for (sourceOffBudget, destinationOffBudget, expectedCategory) in [
            (false, false, nil as String?),
            (false, true, "groceries"),
            (true, false, nil),
            (true, true, nil),
        ] {
            let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
                ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
                UPDATE accounts SET offbudget = \(sourceOffBudget ? 1 : 0) WHERE id = 'checking';
                INSERT INTO accounts VALUES (
                    'destination', 'Destination', \(destinationOffBudget ? 1 : 0), 0, 0, 2
                );
                """))
            let request = AccountLifecycleReviewRequest(
                budgetID: "budget",
                accountID: "checking",
                requestedAction: .close(
                    destinationAccountID: "destination",
                    categoryID: "groceries"
                )
            )

            let review = try await database.accountLifecycleReview(
                request: request,
                localDay: testDay
            )

            guard case .closeWithTransfer(let transfer) = review.resolvedAction else {
                Issue.record("Expected a closing transfer for \(sourceOffBudget) → \(destinationOffBudget)")
                continue
            }
            #expect(transfer.categoryID == expectedCategory)
        }
    }

    private var closeRequest: AccountLifecycleReviewRequest {
        AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )
    }

    private var testDay: AccountLifecycleDay {
        AccountLifecycleDay(isoDate: "2026-09-27", transactionDate: 20260927)
    }
}
