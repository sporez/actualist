import Foundation
import GRDB
import Testing
@testable import Actualist

/// Main-to-dev Phase 3.2 gate: the plan and the stored result of a Bank Sync
/// download are captured before the import reconcile step is extracted from
/// Bank Sync planning, and must stay byte-identical afterwards. One scenario
/// covers every outcome the shared step produces: an exact-id match, a fuzzy
/// same-payee match, a reconciled match, a matched transfer, inserts that create
/// and reuse payees, a rule that renames and categorizes, and a pending row.
@MainActor
struct BankSyncImportEquivalenceTests {
    private let support = LocalFirstActualStoreTests()

    private static let fixtureSQL = """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER
        );
        INSERT INTO rules VALUES (
            'equivalence-rule',
            '[{"field":"imported_payee","op":"is","value":"RULE MERCHANT","type":"string"}]',
            '[{"field":"description","op":"set","value":"coffee","type":"id"},{"field":"category","op":"set","value":"groceries","type":"id"},{"field":"notes","op":"set","value":"Rule applied"}]',
            0
        );
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent, transferred_id)
        VALUES
            ('x-fuzzy', 'savings', 20260302, -1000, NULL, 0, 'coffee', NULL, 0, 0, NULL),
            ('x-exact', 'savings', 20260301, -2500, NULL, 0, NULL, NULL, 0, 0, NULL),
            ('x-recon', 'savings', 20260303, -3300, NULL, 0, 'coffee', NULL, 1, 0, NULL),
            ('xfer-src', 'savings', 20260304, -4400, NULL, 0, 'xfer-checking', 'Transfer note', 0, 0, 'xfer-dst'),
            ('xfer-dst', 'checking', 20260304, 4400, NULL, 0, 'xfer-savings', NULL, 0, 0, 'xfer-src');
        """

    private func download() -> [SimpleFINRemoteTransaction] {
        [
            support.remoteTransaction(id: "bank-fuzzy", amount: "-10.00", dayID: "20260302", payeeName: "Coffee Shop"),
            support.remoteTransaction(id: "bank-exact", amount: "-25.00", dayID: "20260301", payeeName: "Coffee Shop"),
            support.remoteTransaction(id: "bank-recon", amount: "-33.00", dayID: "20260303", payeeName: "Coffee Shop"),
            support.remoteTransaction(id: "bank-xfer", amount: "-44.00", dayID: "20260304", payeeName: "Coffee Shop"),
            support.remoteTransaction(id: "bank-new1", amount: "-5.55", dayID: "20260305", payeeName: "New Merchant"),
            support.remoteTransaction(id: "bank-new2", amount: "-6.66", dayID: "20260306", payeeName: "coffee shop"),
            support.remoteTransaction(id: "bank-rule", amount: "-7.77", dayID: "20260307", payeeName: "RULE MERCHANT"),
            support.remoteTransaction(
                id: "bank-pending", amount: "-1.23", dayID: "20260308", payeeName: "Pending Place", booked: false
            ),
        ]
    }

    private func describe(_ plan: BankSyncReview.AccountPlan) -> String {
        var lines = ["status \(plan.durableStatus)"]
        lines += plan.inserts.map { "insert \($0)" }
        lines += plan.updates.map { "update \($0)" }
        lines += plan.matchDetails.map { "detail \($0)" }
        lines.append("unchanged \(plan.unchangedCount)")
        lines.append("problems \(plan.problems)")
        lines.append("opening \(String(describing: plan.openingBalance))")
        lines.append("balance \(plan.balanceDisposition)")
        return lines.joined(separator: "\n")
    }

    private func mutate(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle, _ sql: String) throws {
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        try DatabaseQueue(path: url.path).write { db in try db.execute(sql: sql) }
    }

    private func dump(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> String {
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        return try queue.readSync { db in
            var lines: [String] = []
            let rows = try Row.fetchAll(db, sql: """
                SELECT CASE WHEN t.id IN ('x-fuzzy', 'x-exact', 'x-recon', 'xfer-src', 'xfer-dst') THEN t.id ELSE 'new' END AS id,
                       t.acct AS acct, t.date AS date, t.amount AS amount,
                       COALESCE(NULLIF(p.name, ''), t.description) AS payee,
                       t.category AS category, t.notes AS notes, t.cleared AS cleared,
                       t.financial_id AS financial_id, t.imported_description AS imported_description,
                       t.transferred_id IS NOT NULL AS is_transfer, t.reconciled AS reconciled
                FROM transactions t LEFT JOIN payees p ON p.id = t.description
                WHERE t.id != 'txn'
                ORDER BY t.date, t.amount, t.acct
                """)
            let columns = [
                "id", "acct", "date", "amount", "payee", "category", "notes", "cleared",
                "financial_id", "imported_description", "is_transfer", "reconciled",
            ]
            for row in rows {
                lines.append(columns.map { "\($0)=\(String(describing: row[$0] as DatabaseValue))" }.joined(separator: " "))
            }
            let payees = try Row.fetchAll(db, sql: "SELECT name, transfer_acct FROM payees ORDER BY name, transfer_acct")
            lines += payees.map { "payee \(String(describing: $0["name"] as String?)) \(String(describing: $0["transfer_acct"] as String?))" }
            let counts = try Row.fetchAll(db, sql: """
                SELECT dataset, "column" AS col, COUNT(*) AS n FROM messages_crdt
                GROUP BY dataset, "column" ORDER BY dataset, "column"
                """)
            lines += counts.map { "messages \($0["dataset"] as String? ?? "") \($0["col"] as String? ?? "") \($0["n"] as Int? ?? 0)" }
            return lines.joined(separator: "\n")
        }
    }

    @Test func downloadPlanAndStoredResultStayByteIdentical() async throws {
        let remote = support.remoteAccount(balance: "100.00")
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [remote.accountID: SimpleFINAccountDownload(
                    transactions: download(), startingBalance: nil, errorType: nil, errorCode: nil
                )],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await support.makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: Self.fixtureSQL
        )
        try mutate(bundle, """
            UPDATE transactions SET financial_id = 'bank-exact' WHERE id = 'x-exact';
            UPDATE transactions SET reconciled = 1 WHERE id = 'x-recon';
            """)
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")

        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        let result = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        let captured = [
            describe(plan),
            "applied inserted \(result.insertedCount) updated \(result.updatedCount) opening \(result.openingBalanceInserted)",
            try dump(bundle),
        ].joined(separator: "\n")
        #expect(captured == Self.golden)
    }

    /// Captured from the pre-extraction implementation (main-to-dev 3.2).
    private static let golden = #"""
status ok
insert Candidate(financialID: Optional("bank-new1"), dayID: "20260305", amountMinorUnits: -555, payeeID: nil, payeeName: Optional("New Merchant"), notes: Optional("coffee ##latte"), categoryID: nil, cleared: true, importedPayee: Optional("New Merchant"), splits: [], scheduleID: nil, clearedIsExplicit: true)
insert Candidate(financialID: Optional("bank-new2"), dayID: "20260306", amountMinorUnits: -666, payeeID: Optional("coffee"), payeeName: Optional("coffee shop"), notes: Optional("coffee ##latte"), categoryID: nil, cleared: true, importedPayee: Optional("coffee shop"), splits: [], scheduleID: nil, clearedIsExplicit: true)
insert Candidate(financialID: Optional("bank-rule"), dayID: "20260307", amountMinorUnits: -777, payeeID: Optional("coffee"), payeeName: Optional("RULE MERCHANT"), notes: Optional("Rule applied"), categoryID: Optional("groceries"), cleared: true, importedPayee: Optional("RULE MERCHANT"), splits: [], scheduleID: nil, clearedIsExplicit: true)
insert Candidate(financialID: Optional("bank-pending"), dayID: "20260308", amountMinorUnits: -123, payeeID: nil, payeeName: Optional("Pending Place"), notes: Optional("coffee ##latte"), categoryID: nil, cleared: false, importedPayee: Optional("Pending Place"), splits: [], scheduleID: nil, clearedIsExplicit: true)
update MatchedUpdate(existingID: "x-fuzzy", financialID: Optional("bank-fuzzy"), payeeID: Optional("coffee"), categoryID: nil, importedPayee: Optional("Coffee Shop"), notes: Optional("coffee ##latte"), cleared: true, childIDs: [])
update MatchedUpdate(existingID: "x-exact", financialID: Optional("bank-exact"), payeeID: Optional("coffee"), categoryID: nil, importedPayee: Optional("Coffee Shop"), notes: Optional("coffee ##latte"), cleared: true, childIDs: [])
update MatchedUpdate(existingID: "xfer-src", financialID: Optional("bank-xfer"), payeeID: Optional("xfer-checking"), categoryID: nil, importedPayee: Optional("Coffee Shop"), notes: Optional("Transfer note"), cleared: true, childIDs: [])
detail MatchDetail(transactionID: "x-fuzzy", dayID: "20260302", amountMinorUnits: -1000, currentPayeeName: Optional("Coffee Shop"), changes: [Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.bankIDAttached, oldValue: nil, newValue: nil), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.bankPayee, oldValue: nil, newValue: Optional("Coffee Shop")), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.notes, oldValue: nil, newValue: Optional("coffee ##latte")), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.cleared, oldValue: Optional("false"), newValue: Optional("true"))])
detail MatchDetail(transactionID: "x-exact", dayID: "20260301", amountMinorUnits: -2500, currentPayeeName: Optional("Coffee Shop"), changes: [Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.payee, oldValue: nil, newValue: Optional("Coffee Shop")), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.bankPayee, oldValue: nil, newValue: Optional("Coffee Shop")), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.notes, oldValue: nil, newValue: Optional("coffee ##latte")), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.cleared, oldValue: Optional("false"), newValue: Optional("true"))])
detail MatchDetail(transactionID: "xfer-src", dayID: "20260304", amountMinorUnits: -4400, currentPayeeName: Optional(""), changes: [Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.bankIDAttached, oldValue: nil, newValue: nil), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.bankPayee, oldValue: nil, newValue: Optional("Coffee Shop")), Actualist.BankSyncReview.MatchChange(field: Actualist.BankSyncReview.MatchChange.Field.cleared, oldValue: Optional("false"), newValue: Optional("true"))])
unchanged 1
problems []
opening nil
balance clear
applied inserted 4 updated 3 opening false
id="x-exact" acct="savings" date=20260301 amount=-2500 payee="Coffee Shop" category=NULL notes="coffee ##latte" cleared=1 financial_id="bank-exact" imported_description="Coffee Shop" is_transfer=0 reconciled=NULL
id="x-fuzzy" acct="savings" date=20260302 amount=-1000 payee="Coffee Shop" category=NULL notes="coffee ##latte" cleared=1 financial_id="bank-fuzzy" imported_description="Coffee Shop" is_transfer=0 reconciled=NULL
id="x-recon" acct="savings" date=20260303 amount=-3300 payee="Coffee Shop" category=NULL notes=NULL cleared=1 financial_id=NULL imported_description=NULL is_transfer=0 reconciled=1
id="xfer-src" acct="savings" date=20260304 amount=-4400 payee="xfer-checking" category=NULL notes="Transfer note" cleared=1 financial_id="bank-xfer" imported_description="Coffee Shop" is_transfer=1 reconciled=NULL
id="xfer-dst" acct="checking" date=20260304 amount=4400 payee="xfer-savings" category=NULL notes=NULL cleared=0 financial_id=NULL imported_description=NULL is_transfer=1 reconciled=NULL
id="new" acct="savings" date=20260305 amount=-555 payee="New Merchant" category=NULL notes="coffee ##latte" cleared=1 financial_id="bank-new1" imported_description="New Merchant" is_transfer=0 reconciled=NULL
id="new" acct="savings" date=20260306 amount=-666 payee="Coffee Shop" category=NULL notes="coffee ##latte" cleared=1 financial_id="bank-new2" imported_description="coffee shop" is_transfer=0 reconciled=NULL
id="new" acct="savings" date=20260307 amount=-777 payee="Coffee Shop" category="groceries" notes="Rule applied" cleared=1 financial_id="bank-rule" imported_description="RULE MERCHANT" is_transfer=0 reconciled=NULL
id="new" acct="savings" date=20260308 amount=-123 payee="Pending Place" category=NULL notes="coffee ##latte" cleared=0 financial_id="bank-pending" imported_description="Pending Place" is_transfer=0 reconciled=NULL
payee Optional("") Optional("checking")
payee Optional("") Optional("credit")
payee Optional("") Optional("savings")
payee Optional("") Optional("tracking")
payee Optional("Coffee Shop") nil
payee Optional("New Merchant") nil
payee Optional("Pending Place") nil
payee Optional("Starting Balance") nil
messages accounts account_id 1
messages accounts account_sync_source 1
messages accounts balance_current 1
messages accounts bank 1
messages accounts bank_sync_status 1
messages accounts last_sync 1
messages payee_mapping targetId 2
messages payees name 2
messages payees tombstone 2
messages transactions acct 4
messages transactions amount 4
messages transactions category 4
messages transactions cleared 7
messages transactions date 4
messages transactions description 5
messages transactions financial_id 6
messages transactions imported_description 7
messages transactions is_parent 4
messages transactions notes 6
messages transactions parent_id 4
messages transactions sort_order 4
messages transactions tombstone 4
"""#
}
