import Foundation
@testable import Actualist

/// The BankSync oracle contract: the shared world rows, and each case's setup, post-mapping
/// candidates, result and after-state. See `scripts/bank-sync-parity/README.md` ("Swift replay").
@MainActor
struct BankSyncOracleFixture {
    static let fileName = "bank-sync-contract.json"
    static let manifestName = "bank-sync-manifest.json"

    let root: [String: Any]
    let worldTables: [String: Any]
    private let entries: [String: [String: Any]]

    var ids: Set<String> { Set(entries.keys) }

    private static var cached: BankSyncOracleFixture?

    /// A missing or malformed file throws; it never yields an empty fixture.
    static func load() throws -> BankSyncOracleFixture {
        if let cached { return cached }
        let url = try ParityOraclePin.fixtureURL("BankSync").appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        let root = try OracleJSON.object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), fileName)
        var byID: [String: [String: Any]] = [:]
        for entry in try OracleJSON.objects(root["cases"], "cases") {
            let id = try OracleJSON.string(entry, "id")
            guard byID[id] == nil else {
                throw OracleReplayError.malformedFixture("duplicate case id \(id)")
            }
            byID[id] = entry
        }
        let fixture = BankSyncOracleFixture(
            root: root,
            worldTables: try OracleJSON.object(root["worldTables"], "worldTables"),
            entries: byID
        )
        cached = fixture
        return fixture
    }

    func entry(_ id: String) throws -> [String: Any] {
        guard let entry = entries[id] else { throw OracleReplayError.unknownCase(id) }
        return entry
    }
}

/// One side of the comparison: the rows and payees after the call, with every id the call minted
/// replaced by a name derived from the row's content, so the two sides need no shared numbering.
enum BankSyncOracleState {
    /// Fields compared per transaction. `raw_synced_data` is excluded (Actualist keeps no provider blob).
    static let transactionFields = [
        "account", "date", "amount", "payee", "imported_payee", "notes", "category", "cleared", "reconciled",
        "imported_id", "schedule", "is_parent", "is_child", "parent_id", "tombstone", "transfer_id",
        "starting_balance_flag", "error",
    ]
    private static let referenceFields: Set<String> = ["id", "transfer_id", "parent_id"]
    private static let flagFields: Set<String> = ["is_parent", "is_child", "starting_balance_flag", "tombstone", "reconciled"]

    /// - Parameters:
    ///   - transactions: public-named rows, ids as the side produced them.
    ///   - payees: `id`, `name`, `transfer_acct`, `tombstone` rows.
    ///   - rules: `id`, `tombstone` rows.
    ///   - baselineTransactionIDs: rows present before the call; every other row is new.
    ///   - baselinePayeeIDs: payees present before the call; every other payee is new.
    static func canonical(
        transactions: [[String: OracleValue]],
        payees: [[String: OracleValue]],
        rules: [[String: OracleValue]],
        baselineTransactionIDs: Set<String>,
        baselinePayeeIDs: Set<String>
    ) -> OracleValue {
        var payeeNames: [String: String] = [:]
        var payeeRows: [String: OracleValue] = [:]
        for payee in payees {
            guard case .string(let id)? = payee["id"] else { continue }
            var mapped = id
            if !baselinePayeeIDs.contains(id), case .string(let name)? = payee["name"] {
                mapped = "new-payee:\(name)"
                payeeNames[id] = mapped
            }
            var row: [String: OracleValue] = [:]
            for key in ["name", "transfer_acct", "tombstone"] { row[key] = payee[key] ?? .null }
            payeeRows[mapped] = .object(row)
        }

        // A new row is named by its content, with ids stripped, in sorted order.
        var staged: [(id: String, row: [String: OracleValue], signature: String)] = []
        for transaction in transactions {
            guard case .string(let id)? = transaction["id"] else { continue }
            var row: [String: OracleValue] = [:]
            for key in transactionFields {
                let value = transaction[key] ?? .null
                row[key] = flagFields.contains(key) && value == .null ? .number(0) : value
            }
            if case .string(let payee)? = row["payee"], let mapped = payeeNames[payee] {
                row["payee"] = .string(mapped)
            }
            // Identity first (opening-balance flag, provider id, account), so a differing amount or date
            // does not shift the names of the other new rows.
            let identity = ["starting_balance_flag", "imported_id", "account"]
            let signature = (identity + transactionFields.filter { !referenceFields.contains($0) && !identity.contains($0) })
                .map { "\($0)=\(row[$0, default: .null].canonical)" }
                .joined(separator: "|")
            staged.append((id, row, signature))
        }
        var names: [String: String] = [:]
        let fresh = staged.filter { !baselineTransactionIDs.contains($0.id) }
            .sorted { ($0.signature, $0.id) < ($1.signature, $1.id) }
        for (index, item) in fresh.enumerated() { names[item.id] = "new-\(index + 1)" }

        var transactionObject: [String: OracleValue] = [:]
        for item in staged {
            var row = item.row
            for key in ["transfer_id", "parent_id"] {
                if case .string(let reference)? = row[key], let mapped = names[reference] {
                    row[key] = .string(mapped)
                }
            }
            transactionObject[names[item.id] ?? item.id] = .object(row)
        }
        var ruleObject: [String: OracleValue] = [:]
        for rule in rules {
            guard case .string(let id)? = rule["id"] else { continue }
            ruleObject[id] = rule["tombstone"] ?? .null
        }
        return .object([
            "transactions": .object(transactionObject),
            "payees": .object(payeeRows),
            "rules": .object(ruleObject),
        ])
    }
}
