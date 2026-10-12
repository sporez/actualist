import Foundation
import GRDB
@testable import Actualist

/// Replays the Transactions oracle contract through the production creation writers on a starter
/// budget seeded with the oracle's synthetic world, and compares the exact CRDT cells each case
/// writes as a multiset. Cell values are canonicalized as `null`, `n:<number>` or `s:<text>`;
/// `sort_order` compares by presence only, because its value is a clock in Actual and a base-plus-index
/// in Actualist. The editor rule that an off-budget account carries no category is applied before the
/// writer, where Actualist owns it.
@MainActor
enum TransactionCreateOracleReplay {
    struct Difference {
        let isMissing: Bool
        let dataset: String
        let row: String
        let column: String
        let value: String

        var line: String {
            "\(isMissing ? "missing" : "extra") in Actualist: \(dataset) \(row) \(column) = \(value)"
        }
    }

    struct Result {
        let expected: [String]
        let actual: [String]
        /// Every cell in `expected` or `actual` that the other side lacks, as a multiset difference.
        let differences: [Difference]
    }

    /// The open divergence that accounts for a difference, or nil when none does (a strict failure).
    /// Which OPs may apply to a case is declared per case in the test; this only attributes lines.
    static func divergence(for difference: Difference, caseID: String) -> String? {
        let structuralColumns: Set = ["tombstone", "isParent", "parent_id", "isChild", "error"]
        let explicitNullColumns: Set = ["notes", "category", "description"]
        if caseID.hasPrefix("manual-no-payee") { return "OP-84" }
        if difference.column == "sort_order", difference.isMissing { return "OP-82" }
        if difference.column == "reconciled", difference.isMissing { return "OP-83" }
        if !difference.isMissing, structuralColumns.contains(difference.column) { return "OP-80" }
        if !difference.isMissing, difference.value == "null", explicitNullColumns.contains(difference.column) {
            return "OP-81"
        }
        if difference.column == "category", difference.value != "null" {
            if caseID == "starting-balance-on-budget" { return "OP-85" }
            if caseID.hasPrefix("transfer-") { return "OP-86" }
        }
        return nil
    }

    private static func differences(expected: [String], actual: [String]) -> [Difference] {
        var remaining = actual
        var result: [Difference] = []
        for cell in expected {
            if let index = remaining.firstIndex(of: cell) {
                remaining.remove(at: index)
            } else {
                result.append(difference(cell, isMissing: true))
            }
        }
        return result + remaining.map { difference($0, isMissing: false) }
    }

    private static func difference(_ cell: String, isMissing: Bool) -> Difference {
        let parts = cell.components(separatedBy: " = ")
        let head = parts[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return Difference(
            isMissing: isMissing,
            dataset: head[0],
            row: head[1],
            column: head[2],
            value: parts.dropFirst().joined(separator: " = ")
        )
    }

    private static let sortOrderToken = "<sort-order>"
    private static let transactionID = "txn-new"

    private static let worldSQL = """
        DELETE FROM transactions; DELETE FROM payee_mapping; DELETE FROM payees;
        DELETE FROM category_mapping; DELETE FROM categories; DELETE FROM category_groups;
        DELETE FROM accounts;
        INSERT INTO category_groups (id, name, is_income, sort_order, tombstone) VALUES
            ('group-oracle', 'Oracle', 0, 16384, 0), ('group-income', 'Income', 1, 32768, 0);
        INSERT INTO categories (id, name, is_income, cat_group, sort_order, tombstone) VALUES
            ('category-food', 'Food', 0, 'group-oracle', 16384, 0),
            ('category-income', 'Income', 1, 'group-income', 16384, 0),
            ('category-starting', 'Starting Balances', 1, 'group-income', 32768, 0);
        INSERT INTO accounts (id, name, offbudget, closed, tombstone, sort_order) VALUES
            ('acct-main', 'Main', 0, 0, 0, 16384), ('acct-target', 'Target', 0, 0, 0, 32768),
            ('acct-off-a', 'Off budget A', 1, 0, 0, 49152), ('acct-off-b', 'Off budget B', 1, 0, 0, 65536),
            ('acct-new', 'New account', 0, 0, 0, 81920);
        INSERT INTO payees (id, name, transfer_acct, tombstone) VALUES
            ('payee-regular', 'Merchant', NULL, 0),
            ('payee-to-main', 'Transfer to Main', 'acct-main', 0),
            ('payee-to-target', 'Transfer to Target', 'acct-target', 0),
            ('payee-to-off-a', 'Transfer to Off A', 'acct-off-a', 0),
            ('payee-to-off-b', 'Transfer to Off B', 'acct-off-b', 0);
        INSERT INTO payee_mapping (id, targetId)
            SELECT id, id FROM payees;
        """

    static func expected(_ entry: [String: Any]) throws -> [String] {
        try OracleJSON.objects(entry["expected"], "expected").map { message in
            cell(
                dataset: try OracleJSON.string(message, "dataset"),
                row: try OracleJSON.string(message, "row"),
                column: try OracleJSON.string(message, "column"),
                value: try canonical(json: message["value"], column: try OracleJSON.string(message, "column"))
            )
        }
    }

    static func replay(_ entry: [String: Any], makeDirectory: () throws -> URL) async throws -> Result {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let input = try OracleJSON.object(entry["input"], "input")
        let url = try makeDirectory().appending(path: "db.sqlite")
        let database = try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
        let queue = try DatabaseQueue(path: url.path)
        let world = worldSQL
        try await queue.write { try $0.execute(sql: world) }

        var builder = LocalFirstSyncMessageBuilder()
        var aliases: [String: String] = [:]
        let messages: [ActualSyncDecodedMessage]
        do {
            switch try OracleJSON.string(entry, "kind") {
            case "manual":
                messages = try await manual(input, database: database, aliases: &aliases, builder: &builder)
            case "transfer":
                messages = try await transfer(input, database: database, aliases: &aliases, builder: &builder)
            case "import":
                messages = try await importedRow(input, database: database, aliases: &aliases, builder: &builder)
            case "starting-balance":
                messages = try await startingBalance(input, database: database, aliases: &aliases, builder: &builder)
            default:
                throw OracleReplayError.malformedFixture("unknown kind in \(try OracleJSON.string(entry, "id"))")
            }
        } catch is LocalFirstError {
            // A refusal writes nothing; the oracle's cells then all count as missing.
            let wanted = try expected(entry)
            return Result(expected: wanted, actual: [], differences: differences(expected: wanted, actual: []))
        }
        let actual = messages.map { message -> String in
            let column = message.column
            let value = canonical(serialized: message.serializedValue, column: column)
            return cell(
                dataset: message.dataset,
                row: aliases[message.row] ?? message.row,
                column: column,
                value: aliasedValue(value, aliases: aliases)
            )
        }
        let wanted = try expected(entry)
        return Result(expected: wanted, actual: actual, differences: differences(expected: wanted, actual: actual))
    }

    // MARK: - Kinds

    private static func manual(
        _ input: [String: Any],
        database: BudgetDatabase,
        aliases: inout [String: String],
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> [ActualSyncDecodedMessage] {
        let accountID = try OracleJSON.string(input, "account")
        var draft = try makeDraft(input, isTransfer: false)
        if try await database.accountIsOffBudget(accountID) {
            draft = draft.withoutBudgetCategory()
        }
        let payee = try await resolvePayee(draft, database: database, aliases: &aliases, builder: &builder)
        let transaction = try await database.createSimpleTransactionMessages(
            draft,
            transactionID: transactionID,
            payeeID: payee.payeeID,
            builder: &builder
        )
        return payee.messages + transaction
    }

    private static func transfer(
        _ input: [String: Any],
        database: BudgetDatabase,
        aliases: inout [String: String],
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> [ActualSyncDecodedMessage] {
        let draft = try makeDraft(input, isTransfer: true)
        let payee = try await resolvePayee(draft, database: database, aliases: &aliases, builder: &builder)
        guard let payeeID = payee.payeeID else {
            throw LocalFirstError.invalidLocalWrite("missing payee")
        }
        let result = try await database.createTransferTransactionMessages(
            draft: draft,
            sourceTransactionID: transactionID,
            payeeID: payeeID,
            builder: &builder
        )
        aliases[result.pairedTransactionID] = "txn-paired"
        return payee.messages + result.messages
    }

    /// Mirrors the insert branch of `LocalFirstActualStore.applyImportReconciliation`: find or create
    /// the payee by name, then the shared simple-row writer with the import draft.
    private static func importedRow(
        _ input: [String: Any],
        database: BudgetDatabase,
        aliases: inout [String: String],
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> [ActualSyncDecodedMessage] {
        let row = try OracleJSON.object(input["transaction"], "transaction")
        let accountID = try OracleJSON.string(input, "account")
        let offBudget = try await database.accountIsOffBudget(accountID)
        let payeeName = row["payee_name"] as? String
        var draft = TransactionDraft(
            accountID: accountID,
            date: try date(try OracleJSON.string(row, "date")),
            amountMinorUnits: OracleJSON.int(row["amount"]) ?? 0,
            payeeID: nil,
            payeeName: payeeName ?? "",
            categoryID: offBudget ? nil : (row["category"] as? String),
            notes: row["notes"] as? String,
            cleared: (row["cleared"] as? Bool) ?? ImportReconcileOptions.csv.defaultCleared,
            isTransfer: false
        )
        // CSV and Bank Sync candidates carry the payee text as the imported payee when no other is given.
        draft.importedPayee = (row["imported_payee"] as? String) ?? payeeName
        draft.importedID = row["imported_id"] as? String
        draft.sortOrder = 1_000
        var payeeMessages: [ActualSyncDecodedMessage] = []
        var payeeID: String?
        if let payeeName, !payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let resolved = try await database.resolveOrCreatePayeeMessages(
                selectedPayeeID: nil,
                payeeName: payeeName,
                builder: &builder
            )
            payeeID = resolved.payeeID
            payeeMessages = resolved.messages
            if !resolved.messages.isEmpty { aliases[resolved.payeeID] = "payee-new" }
        }
        let transaction = try await database.createSimpleTransactionMessages(
            draft,
            transactionID: transactionID,
            payeeID: payeeID,
            builder: &builder
        )
        return payeeMessages + transaction
    }

    private static func startingBalance(
        _ input: [String: Any],
        database: BudgetDatabase,
        aliases: inout [String: String],
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> [ActualSyncDecodedMessage] {
        let dollars = OracleJSON.double(input["balance"]) ?? 0
        let day = try OracleJSON.string(input, "date").replacingOccurrences(of: "-", with: "")
        let messages = try await database.makeBankSyncOpeningBalanceMessages(
            transactionID: transactionID,
            accountID: "acct-new",
            openingBalance: BankSyncReconciliation.OpeningBalance(
                amountMinorUnits: Int((dollars * 100).rounded()),
                dayID: day
            ),
            onBudget: !((input["offBudget"] as? Bool) ?? false),
            sortOrder: 1_000,
            builder: &builder
        )
        if let payeeRow = messages.first(where: { $0.dataset == "payees" })?.row {
            aliases[payeeRow] = "payee-new"
        }
        return messages
    }

    // MARK: - Shared

    /// Mirrors `LocalFirstActualStore.resolvePayeeIfNeeded`, which is private to the store.
    private static func resolvePayee(
        _ draft: TransactionDraft,
        database: BudgetDatabase,
        aliases: inout [String: String],
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> (payeeID: String?, messages: [ActualSyncDecodedMessage]) {
        if let selected = draft.payeeID, !selected.isEmpty {
            try await database.requireLivePayee(selected)
        }
        let resolved = try await database.resolveOrCreatePayeeMessages(
            selectedPayeeID: draft.payeeID,
            payeeName: draft.payeeName,
            builder: &builder
        )
        if !resolved.messages.isEmpty { aliases[resolved.payeeID] = "payee-new" }
        return (resolved.payeeID, resolved.messages)
    }

    private static func makeDraft(_ input: [String: Any], isTransfer: Bool) throws -> TransactionDraft {
        TransactionDraft(
            accountID: try OracleJSON.string(input, "account"),
            date: try date(try OracleJSON.string(input, "date")),
            amountMinorUnits: OracleJSON.int(input["amount"]) ?? 0,
            payeeID: input["payee"] as? String,
            payeeName: input["newPayeeName"] as? String ?? "",
            categoryID: input["category"] as? String,
            notes: input["notes"] as? String,
            cleared: (input["cleared"] as? Bool) ?? false,
            isTransfer: isTransfer
        )
    }

    private static func date(_ iso: String) throws -> Date {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw OracleReplayError.malformedFixture("bad date \(iso)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let date = calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12
        )) else {
            throw OracleReplayError.malformedFixture("bad date \(iso)")
        }
        return date
    }

    private static func cell(dataset: String, row: String, column: String, value: String) -> String {
        "\(dataset) \(row) \(column) = \(value)"
    }

    private static func aliasedValue(_ value: String, aliases: [String: String]) -> String {
        guard value.hasPrefix("s:"), let alias = aliases[String(value.dropFirst(2))] else { return value }
        return "s:\(alias)"
    }

    private static func canonical(json: Any?, column: String) throws -> String {
        switch json {
        case nil, is NSNull:
            return "null"
        case let text as String:
            return column == "sort_order" && text == sortOrderToken ? "present" : "s:\(text)"
        case let number as NSNumber:
            return numberText(number.doubleValue)
        default:
            throw OracleReplayError.malformedFixture("unsupported cell value for \(column)")
        }
    }

    private static func canonical(serialized: String, column: String) -> String {
        switch ReplayNormalizer.parse(serialized) {
        case .null: "null"
        case .number(let number): column == "sort_order" ? "present" : numberText(number)
        case .string(let text): "s:\(text)"
        default: serialized
        }
    }

    private static func numberText(_ number: Double) -> String {
        number == number.rounded() ? "n:\(Int(number))" : "n:\(number)"
    }
}
