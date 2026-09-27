import Foundation
import GRDB

struct ReportExplorerActivityRead: Sendable {
    let currentRequest: TransactionDrilldownRequest
    let current: TransactionDrilldownResult
    let history: TransactionDrilldownResult?
    let catalog: ReportExplorerFilterCatalog
}

extension BudgetDatabase {
    func reportExplorerFilterCatalog(db: Database) throws -> ReportExplorerFilterCatalog {
        let accounts: [ReportExplorerAccountFilterOption]
        if try tableExists("accounts", db: db) {
            let columns = try columnSet(for: "accounts", db: db)
            let name = column("name", fallback: "id", columns: columns)
            let offBudget = column("offbudget", fallback: "0", columns: columns)
            let closed = column("closed", fallback: "0", columns: columns)
            accounts = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, \(name) AS name, \(offBudget) AS offbudget, \(closed) AS closed
                    FROM accounts
                    WHERE \(predicateForLiveRows(columns: columns))
                    ORDER BY lower(\(name)), id
                    """
            ).compactMap { row in
                guard let id = flexibleString(row["id"]), !id.isEmpty else { return nil }
                let rawName = flexibleString(row["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ReportExplorerAccountFilterOption(
                    id: id,
                    name: rawName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Account",
                    isOffBudget: flexibleBool(row["offbudget"]),
                    isClosed: flexibleBool(row["closed"])
                )
            }
        } else {
            accounts = []
        }

        let categories: [ReportExplorerCategoryFilterOption]
        if try tableExists("categories", db: db) {
            let columns = try columnSet(for: "categories", db: db)
            let nameExpression = columns.contains("name") ? "c.name" : "c.id"
            let hiddenExpression = columns.contains("hidden") ? "c.hidden" : "0"
            let incomeExpression = columns.contains("is_income") ? "c.is_income" : "0"
            let groupIDExpression = columns.contains("cat_group")
                ? "c.cat_group"
                : columns.contains("group_id") ? "c.group_id" : "NULL"
            let hasGroups = try tableExists("category_groups", db: db)
            let groupJoin: String
            let groupName: String
            let groupHidden: String
            let groupIncome: String
            if hasGroups {
                let groupColumns = try columnSet(for: "category_groups", db: db)
                groupJoin = "LEFT JOIN category_groups g ON g.id = \(groupIDExpression)"
                groupName = groupColumns.contains("name") ? "g.name" : "g.id"
                groupHidden = groupColumns.contains("hidden") ? "g.hidden" : "0"
                groupIncome = groupColumns.contains("is_income") ? "g.is_income" : "0"
            } else {
                groupJoin = ""
                groupName = "''"
                groupHidden = "0"
                groupIncome = "0"
            }
            categories = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id AS id,
                           \(nameExpression) AS name,
                           \(groupIDExpression) AS group_id,
                           \(groupName) AS group_name,
                           CASE WHEN COALESCE(\(incomeExpression), 0) != 0
                                      OR COALESCE(\(groupIncome), 0) != 0 THEN 1 ELSE 0 END AS is_income,
                           CASE WHEN COALESCE(\(hiddenExpression), 0) != 0
                                      OR COALESCE(\(groupHidden), 0) != 0 THEN 1 ELSE 0 END AS hidden
                    FROM categories c
                    \(groupJoin)
                    WHERE \(predicateForLiveRows(columns: columns, tableAlias: "c"))
                    ORDER BY lower(\(groupName)), lower(\(nameExpression)), c.id
                    """
            ).compactMap { row in
                guard let id = flexibleString(row["id"]), !id.isEmpty else { return nil }
                let rawName = flexibleString(row["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawGroupName = flexibleString(row["group_name"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ReportExplorerCategoryFilterOption(
                    id: id,
                    name: rawName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Category",
                    groupID: flexibleString(row["group_id"]),
                    groupName: rawGroupName.flatMap { $0.isEmpty ? nil : $0 } ?? "Categories",
                    isIncome: flexibleBool(row["is_income"]),
                    isHidden: flexibleBool(row["hidden"])
                )
            }
        } else {
            categories = []
        }
        return ReportExplorerFilterCatalog(accounts: accounts, categories: categories)
    }

    func reportExplorerActivityRead(
        query: ReportExplorerQuery,
        db: Database
    ) throws -> ReportExplorerActivityRead {
        let catalog = try reportExplorerFilterCatalog(db: db)
        let currentRequest = try reportExplorerTransactionRequest(
            query: query,
            startDay: query.startDay,
            endDay: query.endDay,
            catalog: catalog
        )
        let current = try transactionDrilldown(currentRequest, db: db)
        let history: TransactionDrilldownResult?
        if let comparison = query.spendingAverageComparison,
           let first = comparison.history.first,
           let last = comparison.history.last {
            let request = try reportExplorerTransactionRequest(
                query: query,
                startDay: first.startDay,
                endDay: last.endDay,
                catalog: catalog
            )
            history = try transactionDrilldown(request, db: db)
        } else {
            history = nil
        }
        return ReportExplorerActivityRead(
            currentRequest: currentRequest,
            current: current,
            history: history,
            catalog: catalog
        )
    }

    func reportExplorerTransactionRequest(
        query: ReportExplorerQuery,
        startDay: String,
        endDay: String,
        catalog: ReportExplorerFilterCatalog
    ) throws -> TransactionDrilldownRequest {
        guard let start = TransactionQueryDay(rawValue: startDay),
              let end = TransactionQueryDay(rawValue: endDay) else {
            throw ReportExplorerError.invalidRange
        }
        var conditions: [TransactionQueryCondition] = [
            .date(TransactionQueryDateCondition(operation: .isOnOrAfter, day: start)),
            .date(TransactionQueryDateCondition(operation: .isOnOrBefore, day: end)),
            .account(.oneOf(reportExplorerAccountIDs(query: query, catalog: catalog).map { Optional($0) })),
        ]
        if let category = reportExplorerCategoryCondition(query: query, catalog: catalog) {
            conditions.append(.category(category))
        }
        if query.metric == .cashFlow {
            conditions.append(.transfer(false))
        }
        return TransactionDrilldownRequest(
            scope: .spending,
            query: TransactionFeedQuery(conditions: conditions)
        )
    }

    func reportExplorerAccountIDs(
        query: ReportExplorerQuery,
        catalog: ReportExplorerFilterCatalog
    ) -> Set<String> {
        let eligible = Set(catalog.accounts.lazy.filter {
            query.filters.includesOffBudget || !$0.isOffBudget
        }.map(\.id))
        switch query.filters.accounts {
        case .all:
            return eligible
        case .only(let selected):
            return selected.intersection(eligible)
        }
    }

    func reportExplorerCategoryIDs(
        query: ReportExplorerQuery,
        catalog: ReportExplorerFilterCatalog
    ) -> Set<String> {
        let eligible = Set(catalog.categories.lazy.filter {
            !$0.isIncome && (query.filters.includesHiddenCategories || !$0.isHidden)
        }.map(\.id))
        switch query.filters.categories {
        case .all:
            return eligible
        case .only(let selected):
            return selected.intersection(eligible)
        }
    }

    private func reportExplorerCategoryCondition(
        query: ReportExplorerQuery,
        catalog: ReportExplorerFilterCatalog
    ) -> TransactionQueryIDCondition? {
        if case .only(let selected) = query.filters.categories, selected.isEmpty {
            return .oneOf([])
        }
        let options = catalog.categories.filter {
            query.metric == .cashFlow || !$0.isIncome
        }.filter {
            query.filters.includesHiddenCategories || !$0.isHidden
        }
        let eligibleIDs = Set(options.map(\.id))
        let selectedIDs: Set<String>
        switch query.filters.categories {
        case .all:
            selectedIDs = eligibleIDs
        case .only(let selected):
            selectedIDs = selected.intersection(eligibleIDs)
        }

        if case .all = query.filters.categories,
           query.filters.includesHiddenCategories,
           query.filters.includesUncategorized {
            let excludedIncome = catalog.categories.filter(\.isIncome).map { Optional($0.id) }
            return query.metric == .cashFlow || excludedIncome.isEmpty
                ? nil
                : .notOneOf(excludedIncome)
        }
        var values = selectedIDs.map { Optional($0) }
        if query.filters.includesUncategorized {
            values.append(nil)
        }
        return .oneOf(values)
    }
}
