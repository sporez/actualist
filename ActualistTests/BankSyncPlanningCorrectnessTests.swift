import Foundation
import GRDB
import Testing
@testable import Actualist

/// Focused correctness coverage for provider normalization and the store read
/// window that feeds the unchanged three-pass reconciler.
extension LocalFirstActualStoreTests {
    private func correctnessRemoteAccount(currency: String = "USD") -> SimpleFINRemoteAccount {
        SimpleFINRemoteAccount(
            accountID: "sfin-correctness",
            name: "Correctness Checking",
            balance: "0.00",
            currency: currency,
            institution: nil,
            orgName: "Test Bank",
            orgDomain: "test-bank.example",
            orgID: "test-bank"
        )
    }

    private func correctnessTransaction(
        id: String = "bank-correctness",
        dayID: String = "20260302",
        payeeName: String = "Coffee Shop",
        booked: Bool? = true,
        currency: String? = "USD"
    ) -> SimpleFINRemoteTransaction {
        SimpleFINRemoteTransaction(
            id: id,
            dateUnixSeconds: Int64(BankSyncAmounts.date(fromDayID: dayID)!.timeIntervalSince1970),
            amount: "-10.00",
            currency: currency,
            payeeName: payeeName,
            notes: "provider memo",
            booked: booked,
            accountID: "sfin-correctness"
        )
    }

    private func makeLinkedCorrectnessStore(
        transaction: SimpleFINRemoteTransaction,
        additionalFixtureSQL: String = ""
    ) async throws -> (OpenedWritableStoreBundle, StubSimpleFINTransport) {
        let remote = correctnessRemoteAccount(currency: transaction.currency ?? "USD")
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    remote.accountID: SimpleFINAccountDownload(
                        transactions: [transaction],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: additionalFixtureSQL
        )
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")
        return (bundle, transport)
    }

    private func importedRuleFixture(rawPayee: String) -> String {
        """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER
        );
        INSERT INTO rules VALUES (
            'bank-imported-payee-rule',
            '[{"field":"imported_payee","op":"is","value":"\(rawPayee)","type":"string"}]',
            '[{"field":"description","op":"set","value":"coffee","type":"id"},{"field":"category","op":"set","value":"groceries","type":"id"},{"field":"notes","op":"set","value":"Rule applied"}]',
            0
        );
        """
    }

    private func storedCorrectnessRow(
        in bundle: OpenedWritableStoreBundle,
        financialID: String
    ) throws -> Row? {
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        return try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT description, category, notes, imported_description, cleared
                    FROM transactions WHERE financial_id = ?
                    """,
                arguments: [financialID]
            )
        }
    }

    private func storedTransactionID(
        in bundle: OpenedWritableStoreBundle,
        financialID: String
    ) throws -> String? {
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        return try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM transactions WHERE financial_id = ?",
                arguments: [financialID]
            )
        }
    }

    private func existingPayeeRuleFixture(categoryID: String = "groceries") -> String {
        """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER
        );
        INSERT INTO rules VALUES (
            'bank-payee-id-rule',
            '[{"field":"payee","op":"is","value":"coffee","type":"id"}]',
            '[{"field":"category","op":"set","value":"\(categoryID)","type":"id"}]',
            0
        );
        """
    }

    private func existingTransferFixture(
        sourceCategorySQL: String = "NULL",
        destinationPayeeID: String = "xfer-checking",
        destinationAccountID: String = "checking"
    ) -> String {
        """
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent, transferred_id)
        VALUES
            ('xfer-src', 'savings', 20260302, -1000, \(sourceCategorySQL), 0, '\(destinationPayeeID)', NULL, 0, 0, 'xfer-dst'),
            ('xfer-dst', '\(destinationAccountID)', 20260302, 1000, NULL, 0, 'xfer-savings', NULL, 0, 0, 'xfer-src');
        """
    }

    private func storedTransactionRow(
        in bundle: OpenedWritableStoreBundle,
        id: String
    ) throws -> Row? {
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        return try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, acct, description, category, notes, imported_description, cleared,
                           transferred_id, financial_id
                    FROM transactions WHERE id = ?
                    """,
                arguments: [id]
            )
        }
    }

    // MARK: - imported_payee rules in foreground and background paths

    @MainActor
    @Test func syncAllReviewAppliesImportedPayeeRuleWithoutNormalizingOriginal() async throws {
        let rawPayee = "SQ * ORIGINAL MERCHANT #42"
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(payeeName: rawPayee),
            additionalFixtureSQL: importedRuleFixture(rawPayee: rawPayee)
        )
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()

        await model.syncAll()
        #expect(model.phase == .reviewing)
        #expect((model.reviewLines.first?.addedCount ?? 0) >= 1)
        await model.confirmReview()

        let row = try #require(try await storedCorrectnessRow(
            in: bundle,
            financialID: "bank-correctness"
        ))
        #expect(row["description"] as String? == "coffee")
        #expect(row["category"] as String? == "groceries")
        #expect(row["notes"] as String? == "Rule applied")
        #expect(row["imported_description"] as String? == rawPayee)
    }

    @Test func backgroundApplyUsesImportedPayeeRule() async throws {
        let rawPayee = "BACKGROUND RAW MERCHANT 007"
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(
                id: "background-imported-rule",
                payeeName: rawPayee
            ),
            additionalFixtureSQL: importedRuleFixture(rawPayee: rawPayee)
        )

        _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")

        let row = try #require(try await storedCorrectnessRow(
            in: bundle,
            financialID: "background-imported-rule"
        ))
        #expect(row["description"] as String? == "coffee")
        #expect(row["category"] as String? == "groceries")
        #expect(row["notes"] as String? == "Rule applied")
        #expect(row["imported_description"] as String? == rawPayee)
    }

    // MARK: - payee-id rules after name resolution, like loot-core

    @MainActor
    @Test func syncAllReviewAppliesExistingPayeeIDRule() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(payeeName: "Coffee Shop"),
            additionalFixtureSQL: existingPayeeRuleFixture()
        )
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()

        await model.syncAll()
        #expect(model.phase == .reviewing)
        await model.confirmReview()

        let row = try #require(try await storedCorrectnessRow(
            in: bundle,
            financialID: "bank-correctness"
        ))
        #expect(row["description"] as String? == "coffee")
        #expect(row["category"] as String? == "groceries")
        #expect(row["imported_description"] as String? == "Coffee Shop")
    }

    @Test func backgroundApplyUsesExistingPayeeIDRule() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(
                id: "background-payee-id-rule",
                payeeName: "Coffee Shop"
            ),
            additionalFixtureSQL: existingPayeeRuleFixture()
        )

        _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")

        let row = try #require(try await storedCorrectnessRow(
            in: bundle,
            financialID: "background-payee-id-rule"
        ))
        #expect(row["description"] as String? == "coffee")
        #expect(row["category"] as String? == "groceries")
        #expect(row["imported_description"] as String? == "Coffee Shop")
    }

    // MARK: - Existing transfers keep their category

    @MainActor
    @Test func syncAllReviewDoesNotCategorizeMatchedTransfer() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: existingPayeeRuleFixture() + existingTransferFixture()
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        let update = try #require(plan.updates.first { $0.existingID == "xfer-src" })
        #expect(update.categoryID == nil)
        #expect(update.financialID == "bank-correctness")
        #expect(!plan.matchDetails.contains { detail in
            detail.changes.contains { $0.field == .category }
        })

        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        let source = try #require(try await storedTransactionRow(in: bundle, id: "xfer-src"))
        let destination = try #require(try await storedTransactionRow(in: bundle, id: "xfer-dst"))
        #expect(source["category"] as String? == nil)
        #expect(source["transferred_id"] as String? == "xfer-dst")
        #expect(source["financial_id"] as String? == "bank-correctness")
        #expect(source["imported_description"] as String? == "Coffee Shop")
        #expect(destination["category"] as String? == nil)
        #expect(destination["transferred_id"] as String? == "xfer-src")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.row == "xfer-src" && $0.column == "category"
        })
    }

    @Test func backgroundApplyDoesNotCategorizeMatchedTransfer() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(id: "background-transfer-rule"),
            additionalFixtureSQL: existingPayeeRuleFixture() + existingTransferFixture()
        )

        _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")

        let source = try #require(try await storedTransactionRow(in: bundle, id: "xfer-src"))
        #expect(source["category"] as String? == nil)
        #expect(source["transferred_id"] as String? == "xfer-dst")
        #expect(source["financial_id"] as String? == "background-transfer-rule")
        #expect(source["imported_description"] as String? == "Coffee Shop")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.row == "xfer-src" && $0.column == "category"
        })
    }

    @MainActor
    @Test func syncAllReviewAppliesPayeeIDRuleToMatchedOrdinaryTransaction() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: existingPayeeRuleFixture() + """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('ordinary', 'savings', 20260302, -1000, NULL, 0, 'coffee', NULL, 0, 0);
                """
        )
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()
        await model.syncAll()
        await model.confirmReview()

        let row = try #require(try await storedTransactionRow(in: bundle, id: "ordinary"))
        #expect(row["category"] as String? == "groceries")
        #expect(row["financial_id"] as String? == "bank-correctness")
        #expect(row["transferred_id"] as String? == nil)
    }

    @MainActor
    @Test func syncAllReviewPreservesExistingTransferCategory() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: existingPayeeRuleFixture(categoryID: "dining")
                + existingTransferFixture(
                    sourceCategorySQL: "'groceries'",
                    destinationPayeeID: "xfer-tracking",
                    destinationAccountID: "tracking"
                )
        )
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()
        await model.syncAll()
        await model.confirmReview()

        let source = try #require(try await storedTransactionRow(in: bundle, id: "xfer-src"))
        #expect(source["category"] as String? == "groceries")
        #expect(source["transferred_id"] as String? == "xfer-dst")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.row == "xfer-src" && $0.column == "category"
        })
    }

    @Test func matchUpdateWriterDoesNotWriteCategoryOntoExistingTransfer() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: existingTransferFixture()
        )
        let database = try #require(bundle.store.database)
        var builder = LocalFirstSyncMessageBuilder()
        let existing = BankSyncReconciliation.Existing(
            id: "xfer-src",
            financialID: nil,
            dayID: "20260302",
            amountMinorUnits: -1_000,
            payeeID: "xfer-checking",
            categoryID: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            importedPayee: nil,
            isParent: false,
            isChild: false,
            parentID: nil,
            transferID: "xfer-dst"
        )
        let update = BankSyncReconciliation.MatchedUpdate(
            existingID: "xfer-src",
            financialID: "bank-correctness",
            payeeID: "xfer-checking",
            categoryID: "dining",
            importedPayee: "Coffee Shop",
            notes: nil,
            cleared: true,
            childIDs: []
        )

        let messages = try await database.makeBankSyncMatchUpdateMessages(
            update: update,
            existing: existing,
            builder: &builder
        )

        #expect(!messages.contains { $0.column == "category" })
        #expect(messages.contains {
            $0.dataset == "transactions" && $0.row == "xfer-src" && $0.column == "financial_id"
        })
    }

    // MARK: - Off-budget accounts never take a budget category

    private func offBudgetSavingsSQL() -> String {
        "UPDATE accounts SET offbudget = 1 WHERE id = 'savings';\n"
    }

    @MainActor
    @Test func syncAllReviewDoesNotCategorizeMatchedOffBudgetTransaction() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: offBudgetSavingsSQL() + existingPayeeRuleFixture() + """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('ordinary', 'savings', 20260302, -1000, NULL, 0, 'coffee', NULL, 0, 0);
                """
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        let update = try #require(plan.updates.first { $0.existingID == "ordinary" })
        #expect(update.categoryID == nil)
        #expect(update.financialID == "bank-correctness")
        #expect(!plan.matchDetails.contains { detail in
            detail.changes.contains { $0.field == .category }
        })

        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        let row = try #require(try await storedTransactionRow(in: bundle, id: "ordinary"))
        #expect(row["category"] as String? == nil)
        #expect(row["financial_id"] as String? == "bank-correctness")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.row == "ordinary" && $0.column == "category"
        })
    }

    @Test func backgroundApplyDoesNotCategorizeMatchedOffBudgetTransaction() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(id: "background-offbudget-rule"),
            additionalFixtureSQL: offBudgetSavingsSQL() + existingPayeeRuleFixture() + """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('ordinary', 'savings', 20260302, -1000, NULL, 0, 'coffee', NULL, 0, 0);
                """
        )

        _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")

        let row = try #require(try await storedTransactionRow(in: bundle, id: "ordinary"))
        #expect(row["category"] as String? == nil)
        #expect(row["financial_id"] as String? == "background-offbudget-rule")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.row == "ordinary" && $0.column == "category"
        })
    }

    @MainActor
    @Test func syncAllReviewInsertIntoOffBudgetKeepsPayeeAndDropsCategory() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: offBudgetSavingsSQL() + existingPayeeRuleFixture()
        )
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()
        await model.syncAll()
        await model.confirmReview()

        let row = try #require(try await storedCorrectnessRow(
            in: bundle,
            financialID: "bank-correctness"
        ))
        #expect(row["description"] as String? == "coffee")
        #expect(row["category"] as String? == nil)
        #expect(row["imported_description"] as String? == "Coffee Shop")
    }

    private func transferPayeeRuleFixture() -> String {
        """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER
        );
        INSERT INTO rules VALUES (
            'bank-transfer-payee-rule',
            '[{"field":"imported_payee","op":"is","value":"Coffee Shop","type":"string"}]',
            '[{"field":"description","op":"set","value":"xfer-checking","type":"id"}]',
            0
        );
        """
    }

    @MainActor
    @Test func syncAllReviewInsertWithTransferPayeeCreatesPairedRows() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: transferPayeeRuleFixture()
        )
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()
        await model.syncAll()
        await model.confirmReview()

        let source = try #require(try await storedCorrectnessRow(
            in: bundle,
            financialID: "bank-correctness"
        ))
        #expect(source["description"] as String? == "xfer-checking")
        let sourceID = try #require(try await storedTransactionID(
            in: bundle,
            financialID: "bank-correctness"
        ))
        let sourceRow = try #require(try await storedTransactionRow(in: bundle, id: sourceID))
        let pairedID = try #require(sourceRow["transferred_id"] as String?)
        let destination = try #require(try await storedTransactionRow(in: bundle, id: pairedID))
        #expect(destination["acct"] as String? == "checking")
        #expect(destination["transferred_id"] as String? == sourceID)
        #expect(destination["description"] as String? == "xfer-savings")
    }

    @MainActor
    @Test func syncAllReviewDoesNotFillTransferPayeeOnMatchedOrdinaryTransaction() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: transferPayeeRuleFixture() + """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('ordinary', 'savings', 20260302, -1000, NULL, 0, NULL, NULL, 0, 0);
                """
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        let update = try #require(plan.updates.first { $0.existingID == "ordinary" })
        #expect(update.payeeID == nil)
        #expect(update.financialID == "bank-correctness")
        #expect(!plan.matchDetails.contains { detail in
            detail.changes.contains { $0.field == .payee }
        })

        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let row = try #require(try await storedTransactionRow(in: bundle, id: "ordinary"))
        #expect(row["description"] as String? == nil)
        #expect(row["transferred_id"] as String? == nil)
        #expect(row["financial_id"] as String? == "bank-correctness")
    }

    @Test func matchUpdateWriterDoesNotWriteCategoryOntoOffBudgetAccount() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(),
            additionalFixtureSQL: offBudgetSavingsSQL()
        )
        let database = try #require(bundle.store.database)
        var builder = LocalFirstSyncMessageBuilder()
        let existing = BankSyncReconciliation.Existing(
            id: "ordinary",
            financialID: nil,
            dayID: "20260302",
            amountMinorUnits: -1_000,
            payeeID: "coffee",
            categoryID: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            importedPayee: nil,
            isParent: false,
            isChild: false,
            parentID: nil,
            transferID: nil
        )
        let update = BankSyncReconciliation.MatchedUpdate(
            existingID: "ordinary",
            financialID: "bank-correctness",
            payeeID: "coffee",
            categoryID: "dining",
            importedPayee: "Coffee Shop",
            notes: nil,
            cleared: true,
            childIDs: []
        )

        let messages = try await database.makeBankSyncMatchUpdateMessages(
            update: update,
            existing: existing,
            accountIsOffBudget: true,
            builder: &builder
        )

        #expect(!messages.contains { $0.column == "category" })
        #expect(messages.contains {
            $0.dataset == "transactions" && $0.row == "ordinary" && $0.column == "financial_id"
        })
    }

    // MARK: - Store read window across calendar boundaries

    @Test func marchCandidateLoadsEligibleFebruaryTransaction() async throws {
        try await expectExistingTransaction(
            id: "february-match",
            existingDayID: "20260227",
            candidateDayID: "20260302"
        )
    }

    @Test func januaryCandidateLoadsEligibleDecemberTransaction() async throws {
        try await expectExistingTransaction(
            id: "december-match",
            existingDayID: "20251229",
            candidateDayID: "20260102"
        )
    }

    @Test func sameMonthCandidateStillLoadsEligibleTransaction() async throws {
        try await expectExistingTransaction(
            id: "same-month-match",
            existingDayID: "20260301",
            candidateDayID: "20260302"
        )
    }

    @Test func marchCandidateLoadsEligibleLeapDayTransaction() async throws {
        try await expectExistingTransaction(
            id: "leap-day-match",
            existingDayID: "20240229",
            candidateDayID: "20240302"
        )
    }

    private func expectExistingTransaction(
        id: String,
        existingDayID: String,
        candidateDayID: String
    ) async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(dayID: candidateDayID),
            additionalFixtureSQL: """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES
                    ('\(id)', 'savings', \(existingDayID), -1000, NULL, 0, 'coffee', NULL, 0, 0);
                """
        )

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )

        #expect(plan.inserts.isEmpty)
        #expect(plan.updates.map(\.existingID) == [id])
    }

    // MARK: - Unknown booked state is fail-safe uncleared

    @Test func bookedTrueMapsToCleared() async throws {
        #expect(try await plannedCleared(booked: true))
    }

    @Test func bookedFalseMapsToUncleared() async throws {
        #expect(try await plannedCleared(booked: false) == false)
    }

    @Test func missingBookedMapsToUncleared() async throws {
        #expect(try await plannedCleared(booked: nil) == false)
    }

    private func plannedCleared(booked: Bool?) async throws -> Bool {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(booked: booked)
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        return try #require(plan.inserts.first).cleared
    }

    // MARK: - Explicit currency mismatch

    @Test func mismatchedTransactionCurrencyBlocksReviewAndApply() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(currency: "CAD"),
            additionalFixtureSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('defaultCurrencyCode', 'USD');
            """
        )

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )

        #expect(plan.inserts.isEmpty)
        #expect(plan.problems.count == 1)
        #expect(plan.problems.first?.message == "Currency mismatch (CAD bank transaction, USD budget)")
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
    }

    @Test func currencyNeutralBudgetAcceptsSameScaleBankCurrency() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(currency: "CAD")
        )

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )

        #expect(plan.problems.isEmpty)
        #expect(plan.inserts.count == 1)
    }

    @Test func currencyNeutralBudgetRejectsZeroDecimalBankCurrency() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(currency: "JPY")
        )

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )

        #expect(plan.inserts.isEmpty)
        #expect(plan.problems.first?.message == "Currency mismatch (JPY bank transaction, none budget)")
    }

    @Test func missingTransactionCurrencyAlsoBlocksReviewAndApply() async throws {
        let (bundle, _) = try await makeLinkedCorrectnessStore(
            transaction: correctnessTransaction(currency: nil)
        )

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )

        #expect(plan.inserts.isEmpty)
        #expect(plan.problems.first?.message == "Missing transaction currency")
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
    }
}
