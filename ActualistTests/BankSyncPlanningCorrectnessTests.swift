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
    ) async throws -> Row? {
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        return try await queue.read { db in
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
