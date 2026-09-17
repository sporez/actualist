import Foundation
import GRDB
import Testing
@testable import Actualist

/// Pending/notes preferences and custom field mappings through the shared
/// planning path used by foreground Sync All and background Bank Sync.
@MainActor
struct BankSyncNormalizationPreferenceTests {
    private let support = LocalFirstActualStoreTests()
    private func preferenceFixtureSQL(
        pending: String? = nil,
        notes: String? = nil,
        mappings: String? = nil,
        extra: String = ""
    ) -> String {
        var rows: [String] = []
        if let pending {
            rows.append("('sync-import-pending-savings', '\(pending)', 0)")
        }
        if let notes {
            rows.append("('sync-import-notes-savings', '\(notes)', 0)")
        }
        if let mappings {
            let escaped = mappings.replacingOccurrences(of: "'", with: "''")
            rows.append("('custom-sync-mappings-savings', '\(escaped)', 0)")
        }
        let preferences: String
        if rows.isEmpty {
            preferences = ""
        } else {
            preferences = """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER);
                INSERT INTO preferences VALUES \(rows.joined(separator: ", "));
                """
        }
        return preferences + extra
    }

    private func linkedPreferenceStore(
        transactions: [SimpleFINRemoteTransaction],
        startingBalance: Int? = 10_000,
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let remote = support.remoteAccount(balance: "100.00")
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    remote.accountID: SimpleFINAccountDownload(
                        transactions: transactions,
                        startingBalance: startingBalance,
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

    private func bookedAndPendingDownload() -> [SimpleFINRemoteTransaction] {
        [
            support.remoteTransaction(
                id: "booked-1",
                amount: "-10.00",
                dayID: "20260302",
                payeeName: "Coffee Shop",
                booked: true
            ),
            support.remoteTransaction(
                id: "pending-1",
                amount: "-5.00",
                dayID: "20260303",
                payeeName: "Pending Shop",
                booked: false
            )
        ]
    }

    @Test(arguments: [nil as String?, "true"])
    func pendingPreferenceMissingOrTrueImportsBookedAndPending(preference: String?) async throws {
        let bundle = try await linkedPreferenceStore(
            transactions: bookedAndPendingDownload(),
            additionalFixtureSQL: preferenceFixtureSQL(pending: preference)
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(Set(plan.inserts.compactMap(\.financialID)) == ["booked-1", "pending-1"])
        #expect(plan.problems.isEmpty)
        #expect(plan.openingBalance?.amountMinorUnits == 11_500)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let background = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(background.insertedTransactionIDsByAccount["savings"]?.isEmpty != false)
    }

    @Test func pendingPreferenceFalseSkipsPendingBeforePlanning() async throws {
        let bundle = try await linkedPreferenceStore(
            transactions: bookedAndPendingDownload(),
            additionalFixtureSQL: preferenceFixtureSQL(pending: "false")
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.inserts.map(\.financialID) == ["booked-1"])
        #expect(plan.problems.isEmpty)
        #expect(plan.openingBalance?.amountMinorUnits == 11_000)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let ids = try await storedFinancialIDs(in: bundle, accountID: "savings")
        #expect(ids.contains("booked-1"))
        #expect(!ids.contains("pending-1"))
        let background = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(background.insertedTransactionIDsByAccount["savings"]?.isEmpty != false)
    }

    @Test func skippedPendingRowIsNotAProblemAndDoesNotWidenMatchWindow() async throws {
        let bundle = try await linkedPreferenceStore(
            transactions: bookedAndPendingDownload(),
            additionalFixtureSQL: preferenceFixtureSQL(pending: "false") + """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('local-pending-shape', 'savings', 20260303, -500, NULL, 0, NULL, NULL, 0, 0);
                """
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.problems.isEmpty)
        #expect(plan.updates.isEmpty)
        #expect(plan.inserts.map(\.financialID) == ["booked-1"])
    }

    @Test(arguments: [nil as String?, "true"])
    func notesPreferenceMissingOrTrueEscapesProviderNotes(preference: String?) async throws {
        let bundle = try await linkedPreferenceStore(
            transactions: [
                support.remoteTransaction(
                    id: "note-1",
                    amount: "-10.00",
                    dayID: "20260302",
                    payeeName: "Coffee Shop"
                )
            ],
            additionalFixtureSQL: preferenceFixtureSQL(notes: preference)
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.inserts.first?.notes == "coffee ##latte")
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let row = try await storedImportedNotes(in: bundle, financialID: "note-1")
        #expect(row == "coffee ##latte")
    }

    @Test func notesPreferenceFalseDropsProviderNotesBeforeRules() async throws {
        let bundle = try await linkedPreferenceStore(
            transactions: [
                support.remoteTransaction(
                    id: "note-1",
                    amount: "-10.00",
                    dayID: "20260302",
                    payeeName: "Coffee Shop"
                )
            ],
            additionalFixtureSQL: preferenceFixtureSQL(notes: "false")
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.inserts.first?.notes == nil)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        #expect(try await storedImportedNotes(in: bundle, financialID: "note-1") == nil)
        let background = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(background.insertedTransactionIDsByAccount["savings"]?.isEmpty != false)
    }

    @Test func notesPreferenceFalseStillAllowsRuleSetNotes() async throws {
        let bundle = try await linkedPreferenceStore(
            transactions: [
                support.remoteTransaction(
                    id: "note-1",
                    amount: "-10.00",
                    dayID: "20260302",
                    payeeName: "Coffee Shop"
                )
            ],
            additionalFixtureSQL: preferenceFixtureSQL(notes: "false") + """
                CREATE TABLE rules (
                    id TEXT PRIMARY KEY,
                    conditions TEXT,
                    actions TEXT,
                    tombstone INTEGER
                );
                INSERT INTO rules VALUES (
                    'set-notes',
                    '[{"field":"imported_payee","op":"is","value":"Coffee Shop","type":"string"}]',
                    '[{"field":"notes","op":"set","value":"Rule notes"}]',
                    0
                );
                """
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.inserts.first?.notes == "Rule notes")
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        #expect(try await storedImportedNotes(in: bundle, financialID: "note-1") == "Rule notes")
    }

    @Test func customPaymentMappingChangesPayeeAndDate() async throws {
        let seconds = Int64(BankSyncAmounts.date(fromDayID: "20260302")!.timeIntervalSince1970)
        let transaction = SimpleFINRemoteTransaction(
            id: "mapped-1",
            dateUnixSeconds: seconds,
            amount: "-10.00",
            currency: "USD",
            payeeName: "Coffee Shop",
            notes: "provider memo",
            booked: true,
            accountID: "sfin-1",
            rawFields: SimpleFINRawFields([
                "altPayee": .string("Mapped Payee"),
                "altDate": .string("2024-01-15"),
                "altNotes": .string("mapped #note")
            ])
        )
        let bundle = try await linkedPreferenceStore(
            transactions: [transaction],
            additionalFixtureSQL: preferenceFixtureSQL(
                mappings: """
                    {"payment":{"date":"altDate","payee":"altPayee","notes":"altNotes"},\
                    "deposit":{"date":"date","payee":"payeeName","notes":"notes"}}
                    """
            )
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        let insert = try #require(plan.inserts.first)
        #expect(insert.payeeName == "Mapped Payee")
        #expect(insert.importedPayee == "Mapped Payee")
        #expect(insert.dayID == "20240115")
        #expect(insert.notes == "mapped ##note")
    }

    @Test func customMappingNotesStillHonorImportNotesPreference() async throws {
        let seconds = Int64(BankSyncAmounts.date(fromDayID: "20260302")!.timeIntervalSince1970)
        let transaction = SimpleFINRemoteTransaction(
            id: "mapped-notes",
            dateUnixSeconds: seconds,
            amount: "-10.00",
            currency: "USD",
            payeeName: "Coffee Shop",
            notes: "provider memo",
            booked: true,
            accountID: "sfin-1",
            rawFields: SimpleFINRawFields(["altNotes": .string("mapped #note")])
        )
        let bundle = try await linkedPreferenceStore(
            transactions: [transaction],
            additionalFixtureSQL: preferenceFixtureSQL(
                notes: "false",
                mappings: """
                    {"payment":{"date":"date","payee":"payeeName","notes":"altNotes"},\
                    "deposit":{"date":"date","payee":"payeeName","notes":"notes"}}
                    """
            )
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.inserts.first?.notes == nil)
    }

    @Test func malformedCustomMappingIsABlockingProblem() async throws {
        let bundle = try await linkedPreferenceStore(
            transactions: bookedAndPendingDownload(),
            additionalFixtureSQL: preferenceFixtureSQL(mappings: "{")
        )
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.problems == [.invalidCustomMapping])
        #expect(plan.inserts.isEmpty)
        #expect(plan.openingBalance == nil)
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        }
        let ids = try await storedFinancialIDs(in: bundle, accountID: "savings")
        #expect(ids.isEmpty)
    }

    private func storedFinancialIDs(
        in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        accountID: String
    ) async throws -> [String] {
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        return try await queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT financial_id FROM transactions
                    WHERE acct = ? AND IFNULL(tombstone, 0) = 0
                      AND financial_id IS NOT NULL AND financial_id != ''
                    """,
                arguments: [accountID]
            )
        }
    }

    private func storedImportedNotes(
        in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        financialID: String
    ) async throws -> String? {
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        return try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT notes FROM transactions WHERE financial_id = ?",
                arguments: [financialID]
            )
        }
    }
}
