import Foundation
@testable import Actualist

/// Deterministic generated ids (`gen-1`, `gen-2`, ...). Expected outputs name generated rows with
/// `<placeholder>` tokens that `OracleComparison` binds to these ids.
final class SplitIDSequence {
    private var count = 0

    func next() -> String {
        count += 1
        return "gen-\(count)"
    }
}

/// Replays one Splits oracle input through the production split family or rule-split executor,
/// then projects the outcome into the oracle's JSON shape. Rows use camelCase keys; diffs use the
/// snake_case keys the fixture records.
enum SplitOracleReplay {
    static func replay(_ input: [String: Any]) throws -> OracleValue {
        guard let operation = input["operation"] as? String else {
            return try replayRule(input)
        }
        let ids = SplitIDSequence()
        switch operation {
        case "makeChild":
            let parent = try record(OracleJSON.object(input["parent"], "parent"))
            let patches = try OracleJSON.objects(input["data"], "data").map { try patch($0) }
            return .array(patches.map { data in
                row(SplitTransactionFamilyOps.makeChild(parent: parent, data: data, idGenerator: ids.next))
            })
        case "recalculateSplit":
            var groups: [String: OracleValue] = [:]
            for key in ["exact", "mismatch", "mixedSign"] {
                let transaction = try record(OracleJSON.object(input[key], key))
                let result = SplitTransactionFamilyOps.recalculateSplit(transaction)
                groups[key] = .object([
                    "parent": row(result.selected()),
                    "children": .array(result.subtransactions.map { row($0) }),
                ])
            }
            return .object(groups)
        case "splitTransaction":
            let id = try OracleJSON.string(input, "id")
            let children = try records(input["children"], "children")
            let changes = SplitTransactionFamilyOps.splitTransaction(
                try flatten(input),
                id: id,
                createSubtransactions: { _ in children },
                idGenerator: ids.next
            )
            return rowsAndFamily(changes.data, parentID: id)
        case "addSplitTransaction":
            let id = try OracleJSON.string(input, "id")
            let changes = SplitTransactionFamilyOps.addSplitTransaction(
                try flatten(input),
                id: id,
                idGenerator: ids.next
            )
            return rowsAndFamily(changes.data, parentID: id)
        case "updateTransaction":
            let rows = try flatten(input)
            let edited = try editedObject(input)
            let transaction = try record(edited)
            // JSON key presence decides whether a child inherits the parent's payee.
            let conversionChildren = try edited["subtransactions"] == nil
                ? nil
                : OracleJSON.objects(edited["subtransactions"], "subtransactions").map { try patch($0) }
            let changes = SplitTransactionFamilyOps.updateTransaction(
                rows,
                transaction: transaction,
                conversionChildren: conversionChildren,
                idGenerator: ids.next
            )
            return changeSet(changes, parentID: effectiveParentID(rows, id: transaction.id))
        case "deleteTransaction":
            let rows = try flatten(input)
            let id = try OracleJSON.string(input, "id")
            let changes = SplitTransactionFamilyOps.deleteTransaction(rows, id: id)
            return changeSet(changes, parentID: effectiveParentID(rows, id: id))
        default:
            // makeAsNonChildTransactions has no Actualist counterpart; it is oracle-only in the manifest.
            throw OracleReplayError.unknownCase(operation)
        }
    }

    /// Rule fixtures carry a transaction and actions but no `operation`. Conditions are not
    /// evaluated here; the fixture asserts only the action outcome for a matching transaction.
    private static func replayRule(_ input: [String: Any]) throws -> OracleValue {
        let transaction = try record(OracleJSON.object(input["transaction"], "transaction"))
        let actionObjects = try OracleJSON.objects(input["actions"], "actions")
        let actions = try JSONDecoder().decode(
            [RuleAction].self,
            from: JSONSerialization.data(withJSONObject: actionObjects)
        )
        let ids = SplitIDSequence()
        switch RuleSplitActionExecutor.execActions(actions, transaction: transaction, idGenerator: ids.next) {
        case .failedClosed:
            return .string("failedClosed")
        case .applied(let result):
            return .object([
                "parent": row(result.selected()),
                "children": .array(result.subtransactions.map { row($0) }),
            ])
        }
    }

    /// Fixture rows are the flat transaction list Actual stores. A parent's embedded
    /// `subtransactions` are not rows of their own, so a child counts only where it is listed at
    /// top level.
    private static func flatten(_ input: [String: Any]) throws -> [SplitTransactionRecord] {
        try records(input["transactions"], "transactions").map { $0.selected() }
    }

    /// Actual merges an update payload over the stored row, so omitted keys keep their stored
    /// values. Stored embedded children are dropped: the payload's own `subtransactions` decide.
    private static func editedObject(_ input: [String: Any]) throws -> [String: Any] {
        let payload = try OracleJSON.object(input["transaction"], "transaction")
        let id = try OracleJSON.string(payload, "id")
        let stored = try OracleJSON.objects(input["transactions"], "transactions")
            .first { $0["id"] as? String == id }
        guard var merged = stored else {
            return payload
        }
        merged["subtransactions"] = nil
        merged.merge(payload) { _, incoming in incoming }
        return merged
    }

    private static func effectiveParentID(_ rows: [SplitTransactionRecord], id: String) -> String {
        rows.first { $0.id == id }?.effectiveParentID ?? id
    }

    // MARK: - Input decoding

    private static func records(_ value: Any?, _ name: String) throws -> [SplitTransactionRecord] {
        try OracleJSON.objects(value, name).map { try record($0) }
    }

    static func record(_ object: [String: Any]) throws -> SplitTransactionRecord {
        SplitTransactionRecord(
            id: try OracleJSON.string(object, "id"),
            amount: OracleJSON.int(object["amount"]) ?? 0,
            account: object["account"] as? String,
            date: object["date"] as? String,
            category: object["category"] as? String,
            payee: object["payee"] as? String,
            notes: object["notes"] as? String,
            cleared: boolean(object["cleared"]),
            reconciled: boolean(object["reconciled"]),
            startingBalance: boolean(object["starting_balance_flag"]),
            sortOrder: OracleJSON.double(object["sort_order"]),
            isParent: boolean(object["is_parent"]) ?? false,
            isChild: boolean(object["is_child"]) ?? false,
            parentID: object["parent_id"] as? String,
            error: try splitError(object["error"]),
            deleted: boolean(object["deleted"]) ?? false,
            subtransactions: try object["subtransactions"] == nil ? [] : records(object["subtransactions"], "subtransactions")
        )
    }

    /// Omitted keys stay `.omitted` (inherit from the parent); explicit nulls are `.value(nil)`.
    private static func patch(_ object: [String: Any]) throws -> SplitTransactionPatch {
        SplitTransactionPatch(
            id: object["id"] as? String,
            amount: OracleJSON.int(object["amount"]),
            category: optionalText(object, "category"),
            payee: optionalText(object, "payee"),
            notes: optionalText(object, "notes"),
            sortOrder: optionalNumber(object, "sort_order")
        )
    }

    private static func optionalText(_ object: [String: Any], _ key: String) -> SplitOptionalField<String> {
        guard let value = object[key] else { return .omitted }
        return .value(value as? String)
    }

    private static func optionalNumber(_ object: [String: Any], _ key: String) -> SplitOptionalField<Double> {
        guard let value = object[key] else { return .omitted }
        return .value(OracleJSON.double(value))
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? Bool
    }

    private static func splitError(_ value: Any?) throws -> SplitTransactionError? {
        guard let object = value as? [String: Any] else { return nil }
        return SplitTransactionError(
            type: try OracleJSON.string(object, "type"),
            version: OracleJSON.int(object["version"]) ?? 1,
            difference: OracleJSON.int(object["difference"]) ?? 0
        )
    }

    // MARK: - Output projection

    private static func rowsAndFamily(_ rows: [SplitTransactionRecord], parentID: String) -> OracleValue {
        let result = SplitTransactionFamilyOps.family(from: rows, parentID: parentID)
        return .object([
            "rows": .array(result.rows.map { row($0) }),
            "family": family(result.family),
        ])
    }

    private static func changeSet(_ changes: SplitTransactionChangeSet, parentID: String) -> OracleValue {
        .object([
            "result": rowsAndFamily(changes.data, parentID: parentID),
            "diff": diff(changes.diff),
        ])
    }

    private static func family(_ family: SplitTransactionFamily?) -> OracleValue {
        guard let family else { return .null }
        return .object([
            "parent": row(family.parent),
            "children": .array(family.children.map { row($0) }),
        ])
    }

    /// Every row cell, camelCase. Used for output rows, the family, and the rule result.
    static func row(_ record: SplitTransactionRecord) -> OracleValue {
        .object([
            "id": .string(record.id),
            "amount": .number(Double(record.amount)),
            "account": cell(record.account),
            "date": cell(record.date),
            "category": cell(record.category),
            "payee": cell(record.payee),
            "notes": cell(record.notes),
            "cleared": cell(record.cleared),
            "reconciled": cell(record.reconciled),
            "startingBalance": cell(record.startingBalance),
            "sortOrder": cell(record.sortOrder),
            "isParent": bit(record.isParent),
            "isChild": bit(record.isChild),
            "parentID": cell(record.parentID),
            "error": errorValue(record.error),
            "deleted": bit(record.deleted),
        ])
    }

    /// Diff entries: `diffItems` reports the whole record for additions, and only changed cells
    /// for updates; see `sparseUpdate`.
    private static func diff(_ diff: SplitTransactionDiff) -> OracleValue {
        .object([
            "added": .array(diff.added.map { addedRecord($0) }),
            "updated": .array(diff.updated.map { sparseUpdate($0) }),
            "deleted": .array(diff.deleted.map { OracleValue.object(["id": .string($0)]) }),
        ])
    }

    /// Full snake_case record, with every cell present. The fixture omits undefined keys, which
    /// `ReplayNormalizer`-style normalization in `normalized(_:)` treats as absent.
    private static func addedRecord(_ record: SplitTransactionRecord) -> OracleValue {
        .object([
            "id": .string(record.id),
            "amount": .number(Double(record.amount)),
            "account": cell(record.account),
            "date": cell(record.date),
            "category": cell(record.category),
            "payee": cell(record.payee),
            "notes": cell(record.notes),
            "cleared": cell(record.cleared),
            "reconciled": cell(record.reconciled),
            "starting_balance_flag": cell(record.startingBalance),
            "sort_order": cell(record.sortOrder),
            "is_parent": bit(record.isParent),
            "is_child": bit(record.isChild),
            "parent_id": cell(record.parentID),
            "error": errorValue(record.error),
            "deleted": bit(record.deleted),
        ])
    }

    /// Changed cells only, as `getChangedValues` reports them: a cell changed to null, 0, or
    /// false is present with that value.
    private static func sparseUpdate(_ update: SplitTransactionUpdate) -> OracleValue {
        let record = update.record
        var fields: [String: OracleValue] = ["id": .string(record.id)]
        for field in update.changedFields {
            switch field {
            case .amount: fields["amount"] = .number(Double(record.amount))
            case .account: fields["account"] = cell(record.account)
            case .date: fields["date"] = cell(record.date)
            case .category: fields["category"] = cell(record.category)
            case .payee: fields["payee"] = cell(record.payee)
            case .notes: fields["notes"] = cell(record.notes)
            case .cleared: fields["cleared"] = cell(record.cleared)
            case .reconciled: fields["reconciled"] = cell(record.reconciled)
            case .startingBalance: fields["starting_balance_flag"] = cell(record.startingBalance)
            case .sortOrder: fields["sort_order"] = cell(record.sortOrder)
            case .isParent: fields["is_parent"] = bit(record.isParent)
            case .isChild: fields["is_child"] = bit(record.isChild)
            case .parentID: fields["parent_id"] = cell(record.parentID)
            case .transferID: fields["transfer_id"] = cell(record.transferID)
            case .error: fields["error"] = errorValue(record.error)
            case .deleted: fields["deleted"] = bit(record.deleted)
            }
        }
        return .object(fields)
    }

    // MARK: - Cells

    /// Test-side normalization, applied to expected and actual alike before comparison.
    /// Within each diff, arrays are sorted by id because Actual leaves diff order unspecified.
    /// In `added` records only, null cells and false `is_parent`, `is_child`, and `deleted` flags
    /// count as absent, because Actual's fixture omits undefined keys while production records
    /// always carry every cell. Amounts, non-null cells, and `updated` entries are not altered.
    static func normalized(_ value: OracleValue) -> OracleValue {
        switch value {
        case .object(let fields):
            if case .array(let added)? = fields["added"],
               case .array(let updated)? = fields["updated"],
               case .array(let deleted)? = fields["deleted"] {
                var result = fields.mapValues { normalized($0) }
                result["added"] = OracleValue.array(added.map { dropAbsentCells($0) }).sortedByID
                result["updated"] = OracleValue.array(updated).sortedByID
                result["deleted"] = OracleValue.array(deleted).sortedByID
                return .object(result)
            }
            return .object(fields.mapValues { normalized($0) })
        case .array(let items):
            return .array(items.map { normalized($0) })
        default:
            return value
        }
    }

    private static func dropAbsentCells(_ value: OracleValue) -> OracleValue {
        guard case .object(let fields) = value else { return value }
        return .object(fields.filter { key, field in
            if field == .null { return false }
            if ["is_parent", "is_child", "deleted"].contains(key), field == .number(0) { return false }
            return true
        })
    }

    private static func errorValue(_ error: SplitTransactionError?) -> OracleValue {
        guard let error else { return .null }
        return .object([
            "type": .string(error.type),
            "version": .number(Double(error.version)),
            "difference": .number(Double(error.difference)),
        ])
    }

    private static func cell(_ value: String?) -> OracleValue {
        value.map { OracleValue.string($0) } ?? .null
    }

    private static func cell(_ value: Bool?) -> OracleValue {
        value.map { bit($0) } ?? .null
    }

    private static func cell(_ value: Double?) -> OracleValue {
        value.map { OracleValue.number($0) } ?? .null
    }

    /// Booleans compare as 1 and 0, matching how the oracle JSON reads `true` and `false`.
    private static func bit(_ value: Bool) -> OracleValue {
        .number(value ? 1 : 0)
    }
}
