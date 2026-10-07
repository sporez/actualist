import Foundation
import GRDB

extension BudgetDatabase {
    func fetchSavedTransactionFilters() throws -> SavedTransactionFilterReadResult {
        try queue.read { db in
            guard try tableExists("transaction_filters", db: db) else {
                return .unavailable("Saved filters are not available in this budget")
            }
            let columns = try columnSet(for: "transaction_filters", db: db)
            guard columns.isSuperset(of: ["id", "name", "conditions"]) else {
                return .unavailable("Saved-filter data columns are unavailable")
            }

            let joinColumn = columns.contains("conditions_op") ? "conditions_op" : "NULL"
            let tombstoneColumn = columns.contains("tombstone") ? "tombstone" : "0"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, conditions, \(joinColumn) AS conditions_op,
                           \(tombstoneColumn) AS tombstone
                    FROM transaction_filters
                    ORDER BY name, id
                    """
            )
            guard rows.allSatisfy({ $0["id"] as String? != nil }) else {
                return .unavailable("Saved-filter rows are missing stable identifiers")
            }
            let filters: [SavedTransactionFilter] = rows.compactMap { row in
                guard let id = row["id"] as String? else { return nil }
                return SavedTransactionFilter.project(
                    id: id,
                    name: row["name"] as String?,
                    rawConditionsJSON: row["conditions"] as String?,
                    conditionsOperation: row["conditions_op"] as String?,
                    tombstone: ((row["tombstone"] as Int?) ?? 0) != 0
                )
            }.sorted { lhs, rhs in
                let left = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let right = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if left == right { return lhs.id < rhs.id }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            return .available(filters)
        }
    }

    func createSavedTransactionFilter(
        id: String,
        draft: SavedTransactionFilterDraft,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> SavedTransactionFilterCommitReceipt {
        let commit = try commitSavedFilterPlan { db in
            let columns = try writableSavedFilterColumns(db)
            let name = try validatedSavedFilterName(draft.name)
            let peers = try liveSavedFilters(db: db)
            if let duplicate = SavedTransactionFilterComparator.duplicateName(
                candidate: name, excludingID: nil, among: peers
            ) {
                throw SavedTransactionFilterMutationError.duplicateName(duplicate.name).asLocalFirstError
            }
            guard !draft.conditions.isEmpty else {
                throw SavedTransactionFilterMutationError.missingConditions.asLocalFirstError
            }
            if let duplicate = SavedTransactionFilterComparator.duplicateConditions(
                candidate: draft.conditions, join: draft.join, among: peers
            ) {
                throw SavedTransactionFilterMutationError.duplicateConditions(duplicate.name).asLocalFirstError
            }
            let rawConditions = try encodedSupportedConditions(draft.conditions, join: draft.join)
            let messages = try savedFilterMessages(
                id: id,
                name: name,
                conditions: rawConditions,
                join: draft.join,
                tombstone: false,
                columns: columns,
                builder: &builder
            )
            return LocalCommitPlan(drafts: messages, action: nil, outcome: true)
        }
        return SavedTransactionFilterCommitReceipt(
            changed: commit.outcome,
            appliedMessageCount: commit.appliedCount
        )
    }

    func updateSavedTransactionFilter(
        _ update: SavedTransactionFilterUpdate,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> SavedTransactionFilterCommitReceipt {
        let commit = try commitSavedFilterPlan { db in
            let columns = try writableSavedFilterColumns(db)
            let name = try validatedSavedFilterName(update.name)
            let peers = try liveSavedFilters(db: db)
            if let duplicate = SavedTransactionFilterComparator.duplicateName(
                candidate: name, excludingID: update.filterID, among: peers
            ) {
                throw SavedTransactionFilterMutationError.duplicateName(duplicate.name).asLocalFirstError
            }

            guard let current = peers.first(where: { $0.id == update.filterID }) else {
                throw SavedTransactionFilterMutationError.missingFilter.asLocalFirstError
            }
            guard current.isSupported else {
                throw SavedTransactionFilterMutationError.unsupportedFilter.asLocalFirstError
            }
            let rawConditions: String
            let join: RuleConditionJoin
            if let conditions = update.conditions {
                guard !conditions.isEmpty else {
                    throw SavedTransactionFilterMutationError.missingConditions.asLocalFirstError
                }
                join = update.join ?? RuleConditionJoin(rawValue: current.conditionsOperation ?? "and") ?? .and
                if let duplicate = SavedTransactionFilterComparator.duplicateConditions(
                    candidate: conditions,
                    join: join,
                    excludingID: update.filterID,
                    among: peers
                ) {
                    throw SavedTransactionFilterMutationError.duplicateConditions(duplicate.name).asLocalFirstError
                }
                rawConditions = try encodedSupportedConditions(conditions, join: join)
            } else {
                rawConditions = current.rawConditionsJSON ?? "[]"
                join = update.join ?? RuleConditionJoin(rawValue: current.conditionsOperation ?? "and") ?? .and
            }

            let nameChanged = current.rawName != name
            let conditionsChanged = update.conditions != nil
                && (current.rawConditionsJSON != rawConditions || current.conditionsOperation != join.rawValue)
            guard nameChanged || conditionsChanged else {
                return LocalCommitPlan(drafts: [], action: nil, outcome: false)
            }
            let messages = try savedFilterMessages(
                id: update.filterID,
                name: nameChanged ? name : nil,
                conditions: conditionsChanged ? rawConditions : nil,
                join: conditionsChanged ? join : nil,
                tombstone: nil,
                columns: columns,
                builder: &builder
            )
            return LocalCommitPlan(drafts: messages, action: nil, outcome: true)
        }
        return SavedTransactionFilterCommitReceipt(
            changed: commit.outcome,
            appliedMessageCount: commit.appliedCount
        )
    }

    func deleteSavedTransactionFilter(
        id: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> SavedTransactionFilterCommitReceipt {
        let commit = try commitSavedFilterPlan { db in
            _ = try writableSavedFilterColumns(db)
            let peers = try liveSavedFilters(db: db)
            guard peers.contains(where: { $0.id == id }) else {
                throw SavedTransactionFilterMutationError.missingFilter.asLocalFirstError
            }
            let message = try builder.makeMessage(
                dataset: "transaction_filters", row: id, column: "tombstone", value: .bool(true)
            )
            return LocalCommitPlan(drafts: [message], action: nil, outcome: true)
        }
        return SavedTransactionFilterCommitReceipt(
            changed: commit.outcome,
            appliedMessageCount: commit.appliedCount
        )
    }

    private func writableSavedFilterColumns(_ db: Database) throws -> Set<String> {
        guard try tableExists("transaction_filters", db: db) else {
            throw SavedTransactionFilterMutationError.unavailable.asLocalFirstError
        }
        let columns = try columnSet(for: "transaction_filters", db: db)
        guard columns.isSuperset(of: ["id", "name", "conditions", "conditions_op", "tombstone"]) else {
            throw SavedTransactionFilterMutationError.unavailable.asLocalFirstError
        }
        return columns
    }

    private func commitSavedFilterPlan<Outcome: Sendable>(
        prepare: (Database) throws -> LocalCommitPlan<Outcome>
    ) throws -> (outcome: Outcome, appliedCount: Int) {
        try Task.checkCancellation()
        return try commitLocalPlan { db in
            try Task.checkCancellation()
            return try prepare(db)
        }
    }

    private func liveSavedFilters(db: Database) throws -> [SavedTransactionFilter] {
        let columns = try columnSet(for: "transaction_filters", db: db)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, conditions, conditions_op, tombstone
                FROM transaction_filters
                WHERE \(predicateForLiveRows(columns: columns))
                ORDER BY id
                """
        )
        return rows.compactMap { row in
            guard let id = row["id"] as String? else { return nil }
            return SavedTransactionFilter.project(
                id: id,
                name: row["name"] as String?,
                rawConditionsJSON: row["conditions"] as String?,
                conditionsOperation: row["conditions_op"] as String?,
                tombstone: false
            )
        }
    }

    private func validatedSavedFilterName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SavedTransactionFilterMutationError.invalidName.asLocalFirstError }
        return normalized
    }

    private func encodedSupportedConditions(
        _ conditions: [RuleCondition],
        join: RuleConditionJoin
    ) throws -> String {
        let data = try JSONEncoder().encode(conditions)
        let raw = String(decoding: data, as: UTF8.self)
        guard SavedTransactionFilter.project(
            id: "validation", name: "validation", rawConditionsJSON: raw,
            conditionsOperation: join.rawValue, tombstone: false
        ).isSupported else {
            throw SavedTransactionFilterMutationError.unsupportedFilter.asLocalFirstError
        }
        return raw
    }

    private func savedFilterMessages(
        id: String,
        name: String?,
        conditions: String?,
        join: RuleConditionJoin?,
        tombstone: Bool?,
        columns: Set<String>,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        var messages: [ActualSyncDecodedMessage] = []
        if let name {
            messages.append(try builder.makeMessage(
                dataset: "transaction_filters", row: id, column: "name", value: .string(name)
            ))
        }
        if let conditions {
            messages.append(try builder.makeMessage(
                dataset: "transaction_filters", row: id, column: "conditions", value: .string(conditions)
            ))
            if let join, columns.contains("conditions_op") {
                messages.append(try builder.makeMessage(
                    dataset: "transaction_filters", row: id, column: "conditions_op", value: .string(join.rawValue)
                ))
            }
        }
        if let tombstone, columns.contains("tombstone") {
            messages.append(try builder.makeMessage(
                dataset: "transaction_filters", row: id, column: "tombstone", value: .bool(tombstone)
            ))
        }
        return messages
    }
}

private extension SavedTransactionFilterMutationError {
    var asLocalFirstError: LocalFirstError {
        .invalidLocalWrite(errorDescription ?? "The saved filter could not be changed.")
    }
}
