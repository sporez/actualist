import Foundation
import GRDB

extension BudgetDatabase {
    struct TransactionQueryPage: Sendable {
        let transactions: [ActualTransaction]
        let reachedEnd: Bool
        let nextOffset: Int
        let totalMatchCount: Int
        let querySignature: TransactionQuerySignature
        let matchingTransactionIDs: Set<String>
        let contributingTransactionIDs: Set<String>
        let attachedContextTransactionIDs: Set<String>
    }

    func fetchTransactionQueryPage(
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> TransactionQueryPage {
        try queue.read { db in
            try transactionQuerySelection(
                db: db,
                scope: scope,
                query: query,
                limit: limit,
                offset: offset
            ).page
        }
    }

    func fetchTransactionDrilldown(
        _ request: TransactionDrilldownRequest
    ) throws -> TransactionDrilldownResult {
        try queue.read { db in
            let selection = try transactionQuerySelection(
                db: db,
                scope: request.scope,
                query: request.query,
                limit: nil,
                offset: 0
            )
            return TransactionDrilldownResult(
                querySignature: request.query.signature,
                displayTransactions: selection.page.transactions,
                matchingTransactionIDs: selection.page.matchingTransactionIDs,
                contributingTransactions: selection.contributingTransactions,
                attachedContextTransactionIDs: selection.page.attachedContextTransactionIDs,
                totalMatchCount: selection.page.totalMatchCount
            )
        }
    }
}

private struct CompiledTransactionQuery {
    let split: TransactionSplitQueryExpressions
    let joins: TransactionReadJoins
    let normalizedDate: String
    let conditions: [String]
    let arguments: [DatabaseValueConvertible]
    let usesGroupedParentSelection: Bool
    let marksWholeFamiliesMatching: Bool

    var whereSQL: String {
        conditions.joined(separator: " AND ")
    }
}

private struct TransactionQuerySelection {
    let page: BudgetDatabase.TransactionQueryPage
    let contributingTransactions: [ActualTransaction]
}

private extension BudgetDatabase {
    func transactionQuerySelection(
        db: Database,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int?,
        offset: Int
    ) throws -> TransactionQuerySelection {
        guard try tableExists("transactions", db: db) else {
            let page = TransactionQueryPage(
                transactions: [],
                reachedEnd: true,
                nextOffset: max(0, offset),
                totalMatchCount: 0,
                querySignature: query.signature,
                matchingTransactionIDs: [],
                contributingTransactionIDs: [],
                attachedContextTransactionIDs: []
            )
            return TransactionQuerySelection(page: page, contributingTransactions: [])
        }

        let compiled = try compileTransactionQuery(db: db, scope: scope, query: query)
        if query.text == nil {
            return try groupedTransactionQuerySelection(
                db: db,
                query: query,
                compiled: compiled,
                limit: limit,
                offset: offset
            )
        }
        return try flatTransactionQuerySelection(
            db: db,
            query: query,
            compiled: compiled,
            limit: limit,
            offset: offset
        )
    }

    func compileTransactionQuery(
        db: Database,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) throws -> CompiledTransactionQuery {
        let columns = try columnSet(for: "transactions", db: db)
        let split = transactionSplitQueryExpressions(columns: columns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
        var joins = try transactionReadJoins(db: db, split: split, includeNames: true)
        var conditions = [split.liveEffectivePredicate()]
        var arguments: [DatabaseValueConvertible] = []

        if case .account(let accountID) = scope {
            conditions.append("\(split.qualifiedAccount) = ?")
            arguments.append(accountID)
        }

        if query.status == .uncategorized {
            let context = try uncategorizedReadContext(db: db)
            joins = context.joins
            conditions = context.conditions
            if case .account(let accountID) = scope {
                conditions.append("\(split.qualifiedAccount) = ?")
                arguments = [accountID]
            }
            conditions.append(split.splitModePredicate(.inline))
        } else if let status = statusFilterPredicate(query.status, split: split) {
            conditions.append(status)
        }

        if !query.conditions.isEmpty {
            var conditionArguments: [DatabaseValueConvertible] = []
            let predicates = query.conditions.map { condition in
                structuredTransactionPredicate(
                    condition,
                    split: split,
                    joins: joins,
                    normalizedDate: normalizedDate,
                    arguments: &conditionArguments
                )
            }
            let join = query.conditionsJoin == .and ? " AND " : " OR "
            conditions.append("(\(predicates.joined(separator: join)))")
            arguments.append(contentsOf: conditionArguments)
        }

        if let text = query.text {
            conditions.append(transactionSearchPredicate(split: split, joins: joins))
            let like = "%\(escapeLikePattern(text))%"
            arguments.append(contentsOf: Array(repeating: like, count: 4))
        }

        let hasOnlyParentSafeConditions = query.conditions.allSatisfy { condition in
            switch condition {
            case .date, .account: true
            case .payee, .category: false
            }
        }
        let usesGroupedParentSelection = query.text == nil
            && query.status != .uncategorized
            && hasOnlyParentSafeConditions
        let marksWholeFamiliesMatching = usesGroupedParentSelection && query.status == .all
        return CompiledTransactionQuery(
            split: split,
            joins: joins,
            normalizedDate: normalizedDate,
            conditions: conditions,
            arguments: arguments,
            usesGroupedParentSelection: usesGroupedParentSelection,
            marksWholeFamiliesMatching: marksWholeFamiliesMatching
        )
    }

    func groupedTransactionQuerySelection(
        db: Database,
        query: TransactionFeedQuery,
        compiled: CompiledTransactionQuery,
        limit: Int?,
        offset: Int
    ) throws -> TransactionQuerySelection {
        let rowOffset = max(0, offset)
        let rowLimit = limit.map { max(1, $0) }
        let totalMatchCount: Int
        let fetchedGroupIDs: [String]

        if compiled.usesGroupedParentSelection {
            var rootConditions = compiled.conditions
            rootConditions.append(compiled.split.splitModePredicate(.none))
            let rootWhere = rootConditions.joined(separator: " AND ")
            totalMatchCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM transactions t
                    \(compiled.joins.sql)
                    \(compiled.split.parentJoin())
                    WHERE \(rootWhere)
                    """,
                arguments: StatementArguments(compiled.arguments)
            ) ?? 0
            var pageArguments = compiled.arguments
            let limitSQL = transactionQueryLimitSQL(
                limit: rowLimit,
                offset: rowOffset,
                arguments: &pageArguments
            )
            fetchedGroupIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT t.id
                    FROM transactions t
                    \(compiled.joins.sql)
                    \(compiled.split.parentJoin())
                    WHERE \(rootWhere)
                    ORDER BY \(compiled.split.defaultOrder(normalizedDate: compiled.normalizedDate))
                    \(limitSQL)
                    """,
                arguments: StatementArguments(pageArguments)
            )
        } else {
            let matchedRows = matchedTransactionRowsSQL(compiled)
            totalMatchCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(DISTINCT group_id) FROM (\(matchedRows)) matched",
                arguments: StatementArguments(compiled.arguments)
            ) ?? 0
            var pageArguments = compiled.arguments
            let limitSQL = transactionQueryLimitSQL(
                limit: rowLimit,
                offset: rowOffset,
                arguments: &pageArguments
            )
            fetchedGroupIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT groups.group_id
                    FROM (SELECT DISTINCT group_id FROM (\(matchedRows)) matched) groups
                    JOIN transactions t ON t.id = groups.group_id
                    ORDER BY \(compiled.split.defaultOrder(normalizedDate: compiled.normalizedDate))
                    \(limitSQL)
                    """,
                arguments: StatementArguments(pageArguments)
            )
        }

        let reachedEnd = rowLimit.map { fetchedGroupIDs.count <= $0 } ?? true
        let groupIDs = rowLimit.map { Array(fetchedGroupIDs.prefix($0)) } ?? fetchedGroupIDs
        guard !groupIDs.isEmpty else {
            return emptyTransactionQuerySelection(
                query: query,
                offset: rowOffset,
                totalMatchCount: totalMatchCount
            )
        }

        let assembled = try assembledTransactions(
            forGroupIDs: groupIDs,
            db: db,
            split: compiled.split,
            joins: compiled.joins,
            normalizedDate: compiled.normalizedDate
        )
        let displayed = TransactionGroupedOrdering.transactions(assembled, orderedByGroupIDs: groupIDs)
        let physical = physicalTransactions(in: displayed)
        let displayedIDs = Set(physical.compactMap(\.id))
        let matchingIDs: Set<String>
        if compiled.marksWholeFamiliesMatching {
            matchingIDs = displayedIDs
        } else if compiled.usesGroupedParentSelection {
            matchingIDs = Set(groupIDs)
        } else {
            matchingIDs = try matchingTransactionIDs(
                db: db,
                compiled: compiled,
                groupIDs: groupIDs
            )
        }
        return makeTransactionQuerySelection(
            query: query,
            transactions: displayed,
            physicalTransactions: physical,
            matchingIDs: matchingIDs,
            reachedEnd: reachedEnd,
            nextOffset: rowOffset + groupIDs.count,
            totalMatchCount: totalMatchCount
        )
    }

    func flatTransactionQuerySelection(
        db: Database,
        query: TransactionFeedQuery,
        compiled: CompiledTransactionQuery,
        limit: Int?,
        offset: Int
    ) throws -> TransactionQuerySelection {
        let rowOffset = max(0, offset)
        let rowLimit = limit.map { max(1, $0) }
        let totalMatchCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM transactions t
                \(compiled.joins.sql)
                \(compiled.split.parentJoin())
                WHERE \(compiled.whereSQL)
                """,
            arguments: StatementArguments(compiled.arguments)
        ) ?? 0
        var pageArguments = compiled.arguments
        let limitSQL = transactionQueryLimitSQL(
            limit: rowLimit,
            offset: rowOffset,
            arguments: &pageArguments
        )
        let fetchedIDs = try String.fetchAll(
            db,
            sql: """
                SELECT t.id
                FROM transactions t
                \(compiled.joins.sql)
                \(compiled.split.parentJoin())
                WHERE \(compiled.whereSQL)
                ORDER BY \(compiled.split.defaultOrder(normalizedDate: compiled.normalizedDate))
                \(limitSQL)
                """,
            arguments: StatementArguments(pageArguments)
        )
        let reachedEnd = rowLimit.map { fetchedIDs.count <= $0 } ?? true
        let matchingIDs = rowLimit.map { Array(fetchedIDs.prefix($0)) } ?? fetchedIDs
        guard !matchingIDs.isEmpty else {
            return emptyTransactionQuerySelection(
                query: query,
                offset: rowOffset,
                totalMatchCount: totalMatchCount
            )
        }

        let mapped = try transactions(
            forIDs: matchingIDs,
            db: db,
            compiled: compiled
        )
        let displayed = try transactionsByAttachingSplitFamilies(
            mapped,
            db: db,
            split: compiled.split,
            joins: compiled.joins,
            normalizedDate: compiled.normalizedDate
        )
        let physical = physicalTransactions(in: displayed)
        return makeTransactionQuerySelection(
            query: query,
            transactions: displayed,
            physicalTransactions: physical,
            matchingIDs: Set(matchingIDs),
            reachedEnd: reachedEnd,
            nextOffset: rowOffset + matchingIDs.count,
            totalMatchCount: totalMatchCount
        )
    }

    func matchedTransactionRowsSQL(_ compiled: CompiledTransactionQuery) -> String {
        """
        SELECT t.id AS id, IFNULL(\(compiled.split.effectiveParentID), t.id) AS group_id
        FROM transactions t
        \(compiled.joins.sql)
        \(compiled.split.parentJoin())
        WHERE \(compiled.whereSQL)
        """
    }

    func matchingTransactionIDs(
        db: Database,
        compiled: CompiledTransactionQuery,
        groupIDs: [String]
    ) throws -> Set<String> {
        let placeholders = Array(repeating: "?", count: groupIDs.count).joined(separator: ", ")
        var arguments = compiled.arguments
        arguments.append(contentsOf: groupIDs.map { $0 as DatabaseValueConvertible })
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT matched.id
                FROM (\(matchedTransactionRowsSQL(compiled))) matched
                WHERE matched.group_id IN (\(placeholders))
                """,
            arguments: StatementArguments(arguments)
        )
        return Set(ids)
    }

    func transactions(
        forIDs ids: [String],
        db: Database,
        compiled: CompiledTransactionQuery
    ) throws -> [ActualTransaction] {
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(transactionReadSelectList(
                    split: compiled.split,
                    joins: compiled.joins,
                    normalizedDate: compiled.normalizedDate
                ))
                FROM transactions t
                \(compiled.joins.sql)
                \(compiled.split.parentJoin())
                WHERE \(compiled.split.liveEffectivePredicate())
                  AND t.id IN (\(placeholders))
                """,
            arguments: StatementArguments(ids.map { $0 as DatabaseValueConvertible })
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map(mapTransactionRow).compactMap { transaction in
            transaction.id.map { ($0, transaction) }
        })
        return ids.compactMap { byID[$0] }
    }

    func makeTransactionQuerySelection(
        query: TransactionFeedQuery,
        transactions: [ActualTransaction],
        physicalTransactions: [ActualTransaction],
        matchingIDs: Set<String>,
        reachedEnd: Bool,
        nextOffset: Int,
        totalMatchCount: Int
    ) -> TransactionQuerySelection {
        let contributing = physicalTransactions.filter { transaction in
            guard let id = transaction.id else { return false }
            return !transaction.isParent && matchingIDs.contains(id)
        }
        let contributingIDs = Set(contributing.compactMap(\.id))
        let displayedIDs = Set(physicalTransactions.compactMap(\.id))
        let page = TransactionQueryPage(
            transactions: transactions,
            reachedEnd: reachedEnd,
            nextOffset: nextOffset,
            totalMatchCount: totalMatchCount,
            querySignature: query.signature,
            matchingTransactionIDs: matchingIDs,
            contributingTransactionIDs: contributingIDs,
            attachedContextTransactionIDs: displayedIDs.subtracting(matchingIDs)
        )
        return TransactionQuerySelection(page: page, contributingTransactions: contributing)
    }

    func emptyTransactionQuerySelection(
        query: TransactionFeedQuery,
        offset: Int,
        totalMatchCount: Int
    ) -> TransactionQuerySelection {
        let page = TransactionQueryPage(
            transactions: [],
            reachedEnd: true,
            nextOffset: offset,
            totalMatchCount: totalMatchCount,
            querySignature: query.signature,
            matchingTransactionIDs: [],
            contributingTransactionIDs: [],
            attachedContextTransactionIDs: []
        )
        return TransactionQuerySelection(page: page, contributingTransactions: [])
    }

    func physicalTransactions(in transactions: [ActualTransaction]) -> [ActualTransaction] {
        transactions.flatMap { [$0] + $0.subtransactions }
    }

    func transactionQueryLimitSQL(
        limit: Int?,
        offset: Int,
        arguments: inout [DatabaseValueConvertible]
    ) -> String {
        guard let limit else { return "" }
        arguments.append(limit + 1)
        arguments.append(offset)
        return "LIMIT ? OFFSET ?"
    }

    func structuredTransactionPredicate(
        _ condition: TransactionQueryCondition,
        split: TransactionSplitQueryExpressions,
        joins: TransactionReadJoins,
        normalizedDate: String,
        arguments: inout [DatabaseValueConvertible]
    ) -> String {
        switch condition {
        case .date(let date):
            return datePredicate(date, expression: normalizedDate, arguments: &arguments)
        case .account(let ids):
            return idPredicate(ids, expression: split.qualifiedAccount, arguments: &arguments)
        case .payee(let ids):
            return idPredicate(ids, expression: joins.mappedPayee, arguments: &arguments)
        case .category(let ids):
            return idPredicate(ids, expression: joins.mappedCategory, arguments: &arguments)
        }
    }

    func datePredicate(
        _ condition: TransactionQueryDateCondition,
        expression: String,
        arguments: inout [DatabaseValueConvertible]
    ) -> String {
        switch condition.operation {
        case .isOn:
            arguments.append(condition.day.rawValue)
            return "\(expression) = ?"
        case .isApproximately:
            let bounds = approximateDateBounds(condition.day)
            arguments.append(bounds.lower)
            arguments.append(bounds.upper)
            return "(\(expression) >= ? AND \(expression) <= ?)"
        case .isAfter:
            arguments.append(condition.day.rawValue)
            return "\(expression) > ?"
        case .isOnOrAfter:
            arguments.append(condition.day.rawValue)
            return "\(expression) >= ?"
        case .isBefore:
            arguments.append(condition.day.rawValue)
            return "\(expression) < ?"
        case .isOnOrBefore:
            arguments.append(condition.day.rawValue)
            return "\(expression) <= ?"
        }
    }

    func approximateDateBounds(_ day: TransactionQueryDay) -> (lower: String, upper: String) {
        let parts = day.rawValue.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        return (
            transactionQueryDay(calendar.date(byAdding: .day, value: -2, to: date)!, calendar: calendar),
            transactionQueryDay(calendar.date(byAdding: .day, value: 2, to: date)!, calendar: calendar)
        )
    }

    func transactionQueryDay(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    func idPredicate(
        _ condition: TransactionQueryIDCondition,
        expression: String,
        arguments: inout [DatabaseValueConvertible]
    ) -> String {
        switch condition.operation {
        case .isEqual:
            return idEqualityPredicate(
                condition.values.first ?? nil,
                expression: expression,
                negated: false,
                arguments: &arguments
            )
        case .isNotEqual:
            return idEqualityPredicate(
                condition.values.first ?? nil,
                expression: expression,
                negated: true,
                arguments: &arguments
            )
        case .isOneOf, .isNotOneOf:
            guard !condition.values.isEmpty else { return "0 = 1" }
            let negated = condition.operation == .isNotOneOf
            let predicates = condition.values.map { value in
                idEqualityPredicate(
                    value,
                    expression: expression,
                    negated: negated,
                    arguments: &arguments
                )
            }
            return "(\(predicates.joined(separator: negated ? " AND " : " OR ")))"
        }
    }

    func idEqualityPredicate(
        _ value: String?,
        expression: String,
        negated: Bool,
        arguments: inout [DatabaseValueConvertible]
    ) -> String {
        guard let value else {
            return negated ? "\(expression) IS NOT NULL" : "\(expression) IS NULL"
        }
        arguments.append(value)
        return negated
            ? "(\(expression) IS NULL OR \(expression) != ?)"
            : "\(expression) = ?"
    }
}
