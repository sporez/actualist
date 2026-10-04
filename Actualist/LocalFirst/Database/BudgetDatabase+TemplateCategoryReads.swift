import Foundation
import GRDB

extension BudgetDatabase {
    func templateCategoryIsIncomeByID(db: Database) throws -> [String: Bool] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        let isIncome = column("is_income", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(isIncome) AS is_income
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["id"] as String? else {
                    return nil
                }
                return (id, flexibleBool(row["is_income"]))
            }
        )
    }

    func readCategoryGoalDefsRaw(db: Database) throws -> [String: String] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        guard columns.contains("goal_def") else {
            return [:]
        }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, goal_def FROM categories WHERE goal_def IS NOT NULL AND \(predicateForLiveRows(columns: columns))"
        )
        var result: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as String?,
                  let json = row["goal_def"] as String?,
                  !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            result[id] = json
        }
        return result
    }

    func templateCategoryNames(db: Database) throws -> [String: String] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        let name = column("name", fallback: "id", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["id"] as String? else {
                    return nil
                }
                let rawCategoryName: String? = row["name"]
                let categoryName = rawCategoryName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = categoryName.flatMap { $0.isEmpty ? nil : $0 } ?? id
                return (id, label)
            }
        )
    }

    func templateCategoryIDsInCategoryOrder(db: Database) throws -> [String] {
        guard try tableExists("categories", db: db) else {
            return []
        }
        let categoryColumns = try columnSet(for: "categories", db: db)
        var order = [String]()
        if categoryColumns.contains("sort_order") {
            order.append("c.sort_order")
        }
        order.append("c.id")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id
                FROM categories c
                WHERE \(predicateForLiveRows(columns: categoryColumns, tableAlias: "c"))
                ORDER BY \(order.joined(separator: ", "))
                """
        )
        return rows.compactMap { $0["id"] as String? }
    }

    func templateCategoryIDsInBudgetOrder(
        db: Database,
        includeIncome: Bool,
        includeHidden: Bool
    ) throws -> [String] {
        guard try tableExists("categories", db: db) else {
            return []
        }
        let categoryColumns = try columnSet(for: "categories", db: db)
        let groupColumn: String?
        if categoryColumns.contains("cat_group") {
            groupColumn = "cat_group"
        } else if categoryColumns.contains("group_id") {
            groupColumn = "group_id"
        } else {
            groupColumn = nil
        }

        var predicates = [predicateForLiveRows(columns: categoryColumns, tableAlias: "c")]
        if !includeIncome, categoryColumns.contains("is_income") {
            predicates.append("(c.is_income = 0 OR c.is_income IS NULL)")
        }
        if !includeHidden, categoryColumns.contains("hidden") {
            predicates.append("(c.hidden = 0 OR c.hidden IS NULL)")
        }

        let groupsExist = try tableExists("category_groups", db: db)
        let groupColumns = groupsExist ? try columnSet(for: "category_groups", db: db) : []
        var join = ""
        var order: [String] = []
        if groupsExist, let groupColumn {
            if includeHidden {
                join = "LEFT JOIN category_groups g ON g.id = c.\(groupColumn)"
            } else {
                join = "INNER JOIN category_groups g ON g.id = c.\(groupColumn)"
                var visibleParts = [predicateForLiveRows(columns: groupColumns, tableAlias: "g")]
                if groupColumns.contains("hidden") {
                    visibleParts.append("(g.hidden = 0 OR g.hidden IS NULL)")
                }
                predicates.append(visibleParts.joined(separator: " AND "))
            }
            if groupColumns.contains("is_income") {
                order.append("g.is_income")
            }
            if groupColumns.contains("sort_order") {
                order.append("g.sort_order")
            }
            order.append("g.id")
        } else if !includeHidden {
            return []
        }
        if categoryColumns.contains("sort_order") {
            order.append("c.sort_order")
        }
        order.append("c.id")

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id
                FROM categories c
                \(join)
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY \(order.joined(separator: ", "))
                """
        )
        return rows.compactMap { $0["id"] as String? }
    }
}
