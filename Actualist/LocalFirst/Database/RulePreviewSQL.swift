import Foundation
import GRDB

enum RulePreviewSQL {
    static func previewRules(
        for draft: TransactionDraft,
        dateTimeZone: TimeZone = .autoupdatingCurrent,
        in database: isolated BudgetDatabase
    ) throws -> TransactionRulePreview {
        guard let preview = try previewRules(for: [draft], dateTimeZone: dateTimeZone, in: database).first else {
            throw LocalFirstError.invalidLocalWrite("missing rule preview")
        }
        return preview
    }

    /// Evaluates a batch against one immutable rules/schedules/metadata
    /// snapshot. Bank Sync uses this for every downloaded row in a wake so it
    /// does not re-query rule and entity metadata hundreds of times.
    static func previewRules(
        for drafts: [TransactionDraft],
        dateTimeZone: TimeZone = .autoupdatingCurrent,
        in database: isolated BudgetDatabase
    ) throws -> [TransactionRulePreview] {
        try database.queue.read { db in
            try previewRules(for: drafts, dateTimeZone: dateTimeZone, in: database, db: db)
        }
    }

    static func previewRules(
        for drafts: [TransactionDraft],
        dateTimeZone: TimeZone = .autoupdatingCurrent,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [TransactionRulePreview] {
        guard !drafts.isEmpty else { return [] }
        let rules = try RuleSQL.fetchRules(in: database, db: db)
        let schedules = try ScheduleSQL.fetchRuleScheduleIndex(in: database, db: db)
        let metadata = try ruleEvaluationMetadata(in: database, db: db)
        let formulas = rules.compactMap { $0.executionDraft() }.flatMap(\.actions).compactMap { action -> String? in
            if case .string(let formula) = action.options?["formula"] { return formula }
            return nil
        }
        // Keep BALANCE_OF's cutoff on the draft's logical day, not the
        // absolute instant represented by its date-only Date value.
        // A failed prefetch must throw: an empty map would evaluate every
        // BALANCE_OF as 0 and Bank Sync would write that amount.
        let balances = try RuleBalanceOfSQL.prefetchBalanceOf(
            formulas: formulas,
            cutoffs: drafts.map { RuleBalanceOfSQL.BalanceOfCutoff(date: $0.date, sortOrder: $0.sortOrder) },
            dateTimeZone: dateTimeZone,
            in: database,
            db: db
        )
        return drafts.enumerated().map { index, draft in
            var context = ruleEvaluationContext(
                for: draft,
                metadata: metadata,
                dateTimeZone: dateTimeZone
            )
            context.balanceOfPrefetch = balances[index]
            let result = RuleConditionEvaluator.applying(rules, to: context, schedules: schedules)
            return TransactionRulePreview(
                categoryID: result.categoryID,
                notes: result.notes,
                accountID: result.accountID == draft.accountID ? nil : result.accountID,
                payeeID: result.payeeID == draft.payeeID ? nil : result.payeeID,
                clearsPayee: result.payeeID == nil && draft.payeeID != nil,
                amountMinorUnits: result.amount == draft.amountMinorUnits ? nil : result.amount,
                date: ActualDateOnly.dayID(from: result.date, timeZone: dateTimeZone)
                    == ActualDateOnly.dayID(from: draft.date, timeZone: dateTimeZone)
                    ? nil
                    : result.date,
                cleared: result.cleared == draft.cleared ? nil : result.cleared,
                scheduleID: result.scheduleID,
                deletesTransaction: result.deletesTransaction,
                splits: result.splits.map { split in
                    TransactionSplitDraft(
                        id: split.id,
                        categoryID: split.categoryID,
                        categoryName: split.categoryID.flatMap { result.categoryNames[$0] },
                        amountMinorUnits: split.amount,
                        payeeID: .value(split.payeeID),
                        notes: .value(split.notes),
                        sortOrder: .value(split.sortOrder)
                    )
                }
            )
        }
    }

    static func previewRules(
        for draft: TransactionDraft,
        dateTimeZone: TimeZone = .autoupdatingCurrent,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> TransactionRulePreview {
        guard let preview = try previewRules(for: [draft], dateTimeZone: dateTimeZone, in: database, db: db).first else {
            throw LocalFirstError.invalidLocalWrite("missing rule preview")
        }
        return preview
    }

    static func fetchMatchingTransactions(
        for draft: RuleDraft,
        limit: Int,
        dateTimeZone: TimeZone = .autoupdatingCurrent,
        in database: isolated BudgetDatabase
    ) throws -> RuleTransactionMatchPreview {
        guard !draft.conditions.isEmpty else {
            return RuleTransactionMatchPreview(transactions: [], totalCount: 0)
        }

        let transactions = try database.fetchTransactions()
        let metadata = try ruleEvaluationMetadata(in: database)
        let matches = transactions.compactMap { transaction -> RuleTransactionMatch? in
            guard let context = ruleEvaluationContext(
                for: transaction,
                metadata: metadata,
                dateTimeZone: dateTimeZone
            ),
                  RuleConditionEvaluator.conditionsMatch(draft, context: context),
                  let id = transaction.id else { return nil }
            let isTransfer = transaction.payee.map { metadata.transferPayeeIDs.contains($0) } ?? false
            let categoryName: String
            if let categoryID = transaction.category {
                categoryName = metadata.categoryNames[categoryID] ?? "Deleted category"
            } else {
                categoryName = isTransfer ? "Account Transfer" : "Uncategorized"
            }
            return RuleTransactionMatch(
                id: id,
                date: transaction.date,
                payeeName: transaction.payeeName
                    ?? transaction.payee.flatMap { metadata.payeeNames[$0] }
                    ?? transaction.importedPayee
                    ?? "Unknown payee",
                categoryName: categoryName,
                accountName: metadata.accountNames[transaction.account] ?? "Deleted account",
                amountMinorUnits: transaction.amount ?? 0
            )
        }

        return RuleTransactionMatchPreview(
            transactions: Array(matches.prefix(max(0, limit))),
            totalCount: matches.count
        )
    }

    private struct RuleEvaluationMetadata {
        let accountNames: [String: String]
        let offBudgetAccountIDs: Set<String>
        let categoryNames: [String: String]
        let categoryGroupsByCategoryID: [String: String]
        let categoryGroupNames: [String: String]
        let payeeNames: [String: String]
        let transferPayeeIDs: Set<String>
    }

    private static func ruleEvaluationMetadata(in database: isolated BudgetDatabase) throws -> RuleEvaluationMetadata {
        try database.queue.read { db in try ruleEvaluationMetadata(in: database, db: db) }
    }

    private static func ruleEvaluationMetadata(in database: isolated BudgetDatabase, db: Database) throws -> RuleEvaluationMetadata {
            var accountNames: [String: String] = [:]
            var offBudgetAccountIDs = Set<String>()
            if try database.tableExists("accounts", db: db) {
                let columns = try database.columnSet(for: "accounts", db: db)
                let name = columns.contains("name") ? "name" : "''"
                let offbudget = columns.contains("offbudget") ? "offbudget" : "0"
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, \(name) AS name, \(offbudget) AS offbudget FROM accounts"
                )
                for row in rows {
                    guard let id = row["id"] as String? else { continue }
                    accountNames[id] = row["name"] ?? ""
                    if SQLiteValueCoercion.lenientBool(row["offbudget"]) { offBudgetAccountIDs.insert(id) }
                }
            }
            var categoryNames: [String: String] = [:]
            var categoryGroupsByCategoryID: [String: String] = [:]
            var categoryGroupNames: [String: String] = [:]
            if try database.tableExists("category_groups", db: db) {
                let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM category_groups")
                categoryGroupNames = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    guard let id = row["id"] as String? else { return nil }
                    return (id, row["name"] as String? ?? "")
                })
            }
            if try database.tableExists("categories", db: db) {
                let columns = try database.columnSet(for: "categories", db: db)
                let group = columns.contains("cat_group") ? "cat_group" : columns.contains("group_id") ? "group_id" : nil
                let groupSelection = group.map { "\(database.quotedIdentifier($0)) AS group_id" } ?? "NULL AS group_id"
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, name, \(groupSelection) FROM categories"
                )
                for row in rows {
                    guard let id = row["id"] as String? else { continue }
                    categoryNames[id] = row["name"] ?? ""
                    if let groupID = row["group_id"] as String? {
                        categoryGroupsByCategoryID[id] = groupID
                    }
                }
            }
            var payeeNames: [String: String] = [:]
            var transferPayeeIDs = Set<String>()
            if try database.tableExists("payees", db: db) {
                let columns = try database.columnSet(for: "payees", db: db)
                let transferAccount = columns.contains("transfer_acct") ? "transfer_acct" : "NULL"
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, name, \(transferAccount) AS transfer_account FROM payees"
                )
                for row in rows {
                    guard let id = row["id"] as String? else { continue }
                    let transferAccountID = row["transfer_account"] as String?
                    if transferAccountID != nil { transferPayeeIDs.insert(id) }
                    let rawName = row["name"] as String? ?? ""
                    payeeNames[id] = rawName.isEmpty
                        ? transferAccountID.flatMap { accountNames[$0] } ?? ""
                        : rawName
                }
            }
            return RuleEvaluationMetadata(
                accountNames: accountNames,
                offBudgetAccountIDs: offBudgetAccountIDs,
                categoryNames: categoryNames,
                categoryGroupsByCategoryID: categoryGroupsByCategoryID,
                categoryGroupNames: categoryGroupNames,
                payeeNames: payeeNames,
                transferPayeeIDs: transferPayeeIDs
            )
    }

    static func rulePayeeName(for payeeID: String?, in database: isolated BudgetDatabase, db: Database) throws -> String? {
        guard let payeeID else { return nil }
        return try ruleEvaluationMetadata(in: database, db: db).payeeNames[payeeID]
    }

    private static func ruleEvaluationContext(
        for draft: TransactionDraft,
        metadata: RuleEvaluationMetadata,
        dateTimeZone: TimeZone = .autoupdatingCurrent
    ) -> RuleEvaluationContext {
        let effectiveCategoryID = draft.isParent ? nil : draft.categoryID
        let categoryGroupID = effectiveCategoryID.flatMap { metadata.categoryGroupsByCategoryID[$0] }
        return RuleEvaluationContext(
            accountID: draft.accountID,
            accountName: metadata.accountNames[draft.accountID] ?? "",
            accountIsOffBudget: metadata.offBudgetAccountIDs.contains(draft.accountID),
            amount: draft.amountMinorUnits,
            categoryID: effectiveCategoryID,
            categoryName: effectiveCategoryID.flatMap { metadata.categoryNames[$0] },
            categoryGroupID: categoryGroupID,
            categoryGroupName: categoryGroupID.flatMap { metadata.categoryGroupNames[$0] },
            date: draft.date,
            dateTimeZone: dateTimeZone,
            notes: draft.notes,
            payeeID: draft.payeeID,
            payeeName: draft.payeeName,
            importedPayee: draft.importedPayee,
            cleared: draft.cleared,
            reconciled: draft.reconciled,
            isTransfer: draft.isTransfer,
            isParent: draft.isParent,
            sortOrder: draft.sortOrder,
            scheduleID: draft.scheduleID,
            accountNames: metadata.accountNames,
            offBudgetAccountIDs: metadata.offBudgetAccountIDs,
            categoryNames: metadata.categoryNames,
            categoryGroupsByCategoryID: metadata.categoryGroupsByCategoryID,
            categoryGroupNames: metadata.categoryGroupNames,
            payeeNames: metadata.payeeNames
        )
    }

    private static func ruleEvaluationContext(
        for transaction: ActualTransaction,
        metadata: RuleEvaluationMetadata,
        dateTimeZone: TimeZone
    ) -> RuleEvaluationContext? {
        guard let date = ActualDateOnly.date(from: transaction.date, timeZone: dateTimeZone) else { return nil }
        let effectiveCategoryID = transaction.isParent ? nil : transaction.category
        let categoryGroupID = effectiveCategoryID.flatMap { metadata.categoryGroupsByCategoryID[$0] }
        return RuleEvaluationContext(
            evaluationID: transaction.id ?? "parent-1",
            accountID: transaction.account,
            accountName: metadata.accountNames[transaction.account] ?? "",
            accountIsOffBudget: metadata.offBudgetAccountIDs.contains(transaction.account),
            amount: transaction.amount ?? 0,
            categoryID: effectiveCategoryID,
            categoryName: effectiveCategoryID.flatMap { metadata.categoryNames[$0] },
            categoryGroupID: categoryGroupID,
            categoryGroupName: categoryGroupID.flatMap { metadata.categoryGroupNames[$0] },
            date: date,
            dateTimeZone: dateTimeZone,
            notes: transaction.notes,
            payeeID: transaction.payee,
            payeeName: transaction.payeeName
                ?? transaction.payee.flatMap { metadata.payeeNames[$0] }
                ?? "",
            importedPayee: transaction.importedPayee,
            cleared: transaction.cleared?.boolValue == true,
            reconciled: transaction.reconciled,
            isTransfer: transaction.payee.map { metadata.transferPayeeIDs.contains($0) } ?? false,
            isParent: transaction.isParent,
            isChild: transaction.isChild,
            parentID: transaction.parentID,
            scheduleID: transaction.schedule,
            accountNames: metadata.accountNames,
            offBudgetAccountIDs: metadata.offBudgetAccountIDs,
            categoryNames: metadata.categoryNames,
            categoryGroupsByCategoryID: metadata.categoryGroupsByCategoryID,
            categoryGroupNames: metadata.categoryGroupNames,
            payeeNames: metadata.payeeNames
        )
    }
}
