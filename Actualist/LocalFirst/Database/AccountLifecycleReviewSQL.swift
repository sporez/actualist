import Foundation
import GRDB

struct AccountLifecycleScheduleFacts: Sendable {
    let references: [AccountScheduleReference]
    let digest: String
    let inspectionAvailable: Bool
}

enum AccountLifecycleDigest {
    static func make(_ components: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for component in components {
            for byte in component.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

enum AccountLifecycleReviewSQL {
    static func accountLifecycleAccounts(in database: isolated BudgetDatabase) throws -> [AccountLifecycleAccount] {
        try database.queue.read { db in
            try accountLifecycleAccounts(in: database, db: db)
        }
    }

    static func accountLifecycleReview(
        request: AccountLifecycleReviewRequest,
        localDay: AccountLifecycleDay = .localGregorian(),
        in database: isolated BudgetDatabase
    ) throws -> AccountLifecycleReview {
        try database.queue.read { db in
            try accountLifecycleReview(
                request: request,
                localDay: localDay,
                in: database,
                db: db
            )
        }
    }

    static func accountLifecycleReview(
        request: AccountLifecycleReviewRequest,
        localDay: AccountLifecycleDay,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> AccountLifecycleReview {
        let accountID = request.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            throw AccountLifecycleCommandError.accountNotFound
        }

        let accounts = try accountLifecycleAccounts(in: database, db: db)
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AccountLifecycleCommandError.accountNotFound
        }
        let graph = try accountLifecycleTransactionGraph(accountID: accountID, in: database, db: db)
        let destinations = accounts
            .filter { !$0.isClosed && $0.id != accountID }
            .map {
                AccountLifecycleDestination(id: $0.id, name: $0.name, offBudget: $0.offBudget)
            }
        let categories = try accountLifecycleCategories(in: database, db: db)
        let bankLink = try accountLifecycleBankLink(accountID: accountID, in: database, db: db)
        let schedules = try accountLifecycleScheduleFacts(accountID: accountID, in: database, db: db)

        var blockers: [AccountLifecycleBlocker] = []
        if account.isClosed {
            blockers.append(.accountAlreadyClosed)
        }
        if !schedules.inspectionAvailable {
            blockers.append(.scheduleInspectionUnavailable)
        }
        if let bankLink, bankLink.provider != .simpleFIN {
            blockers.append(.unsupportedBankProvider(bankLink.provider))
        }

        var destinationFacts: AccountLifecycleDestinationFacts?
        var categoryFacts: AccountLifecycleCategoryFacts?
        var resolvedAction: AccountLifecycleResolvedAction?

        switch request.requestedAction {
        case .close(let destinationAccountID, let categoryID):
            if graph.liveTransactionCount == 0 {
                resolvedAction = .deleteEmptyAccount
            } else if graph.liveBalance == 0 {
                resolvedAction = .closeAtZero
            } else {
                let destination = destinationAccountID.flatMap { requestedID in
                    destinations.first(where: { $0.id == requestedID })
                }
                if destinationAccountID == accountID {
                    blockers.append(.destinationIsSource)
                } else if destinationAccountID == nil {
                    blockers.append(.destinationRequired)
                } else if destination == nil {
                    blockers.append(.destinationUnavailable)
                }

                if let destination {
                    destinationFacts = AccountLifecycleDestinationFacts(account: destination)
                    let categoryRequired = !account.offBudget && destination.offBudget
                    let category = categoryID.flatMap { requestedID in
                        categories.first(where: { $0.id == requestedID })
                    }
                    if categoryRequired && categoryID == nil {
                        blockers.append(.categoryRequired)
                    } else if categoryID != nil && category == nil {
                        blockers.append(.categoryUnavailable)
                    }
                    if let category {
                        categoryFacts = AccountLifecycleCategoryFacts(category: category)
                    }
                    if blockers.isEmpty {
                        resolvedAction = .closeWithTransfer(AccountClosingTransfer(
                            destinationAccountID: destination.id,
                            sourceAmount: try accountLifecycleNegated(graph.liveBalance),
                            destinationAmount: graph.liveBalance,
                            categoryID: categoryRequired ? category?.id : nil,
                            date: localDay.isoDate,
                            notes: "Closing account"
                        ))
                    }
                }
            }
        }

        let sourceFacts = AccountLifecycleSourceFacts(
            account: account,
            liveBalance: graph.liveBalance,
            liveTransactionCount: graph.liveTransactionCount,
            liveFamilyCount: graph.liveFamilyCount,
            pairedTransferCount: graph.pairedTransferCount
        )
        return AccountLifecycleReview(
            identity: AccountLifecycleReviewIdentity(
                budgetID: request.budgetID,
                accountID: accountID,
                action: request.requestedAction,
                localDay: localDay,
                sourceFacts: sourceFacts,
                destinationFacts: destinationFacts,
                categoryFacts: categoryFacts,
                transactionGraphDigest: graph.digest,
                scheduleDigest: schedules.digest,
                bankLinkIdentity: bankLink?.identity
            ),
            account: account,
            liveBalance: graph.liveBalance,
            liveTransactionCount: graph.liveTransactionCount,
            liveFamilyCount: graph.liveFamilyCount,
            pairedTransferCount: graph.pairedTransferCount,
            bankLink: bankLink,
            activeScheduleReferences: schedules.references,
            eligibleDestinations: destinations,
            eligibleCategories: categories,
            resolvedAction: blockers.isEmpty ? resolvedAction : nil,
            blockers: blockers
        )
    }

    static func accountLifecycleAccounts(in database: isolated BudgetDatabase, db: Database) throws -> [AccountLifecycleAccount] {
        guard try database.tableExists("accounts", db: db) else {
            throw AccountLifecycleCommandError.missingAccountSchema
        }
        let columns = try database.columnSet(for: "accounts", db: db)
        guard columns.isSuperset(of: ["id", "name", "offbudget", "closed"]) else {
            throw AccountLifecycleCommandError.missingAccountSchema
        }
        let groupID = database.column("account_group_id", fallback: "NULL", columns: columns)
        let order = columns.contains("sort_order") ? "sort_order, id" : "id"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, offbudget, closed, \(groupID) AS account_group_id
                FROM accounts
                WHERE \(database.predicateForLiveRows(columns: columns))
                ORDER BY \(order)
                """
        ).compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else { return nil }
            let rawGroupID = row["account_group_id"] as String?
            return AccountLifecycleAccount(
                id: id,
                name: row["name"] ?? "",
                offBudget: SQLiteValueCoercion.lenientBool(row["offbudget"]),
                isClosed: SQLiteValueCoercion.lenientBool(row["closed"]),
                accountGroupID: rawGroupID?.isEmpty == false ? rawGroupID : nil
            )
        }
    }

    private struct AccountLifecycleGraphFacts {
        let liveBalance: Int
        let liveTransactionCount: Int
        let liveFamilyCount: Int
        let pairedTransferCount: Int
        let digest: String
    }

    private struct AccountLifecycleTransactionFact {
        let id: String
        let accountID: String
        let date: String
        let amount: String
        let categoryID: String
        let payeeID: String
        let notes: String
        let parentID: String?
        let isParent: Bool
        let isChild: Bool
        let transferID: String?

        var familyID: String { isChild ? (parentID ?? id) : id }

        var canonicalComponents: [String] {
            [
                id, accountID, date, amount, categoryID, payeeID, notes,
                parentID ?? "", isParent ? "1" : "0", isChild ? "1" : "0",
                transferID ?? "",
            ]
        }
    }

    private static func accountLifecycleTransactionGraph(
        accountID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> AccountLifecycleGraphFacts {
        guard try database.tableExists("transactions", db: db) else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }
        let columns = try database.columnSet(for: "transactions", db: db)
        guard columns.contains("id"), columns.contains("date"), columns.contains("amount"),
              TransactionRowColumns.account(in: columns) != nil else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }
        guard let transferColumn = TransactionRowColumns.transferID(in: columns) else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }

        let split = TransactionSplitQueryExpressions(columns: columns)
        let balanceRow = try Row.fetchOne(
            db,
            sql: """
                SELECT SUM(\(split.qualifiedAmount)) AS balance
                FROM transactions t
                \(split.parentJoin())
                WHERE \(split.liveInlinePredicate())
                  AND \(split.qualifiedAccount) = ?
                """,
            arguments: [accountID]
        )
        let liveBalance = try accountLifecycleInteger(balanceRow?["balance"])
        let sourceRows = try accountLifecycleTransactionFacts(
            whereClause: "\(split.qualifiedAccount) = ?",
            arguments: [accountID],
            columns: columns,
            transferColumn: transferColumn,
            in: database,
            db: db
        )
        let pairedIDs = Set(sourceRows.compactMap(\.transferID))
        let pairedRows: [AccountLifecycleTransactionFact]
        if pairedIDs.isEmpty {
            pairedRows = []
        } else {
            let placeholders = Array(repeating: "?", count: pairedIDs.count).joined(separator: ", ")
            pairedRows = try accountLifecycleTransactionFacts(
                whereClause: "t.id IN (\(placeholders))",
                arguments: StatementArguments(pairedIDs.sorted()),
                columns: columns,
                transferColumn: transferColumn,
                in: database,
                db: db
            )
        }
        let pairedRowIDs = Set(pairedRows.map(\.id))
        let digestRows = (sourceRows + pairedRows).sorted { $0.id < $1.id }
        return AccountLifecycleGraphFacts(
            liveBalance: liveBalance,
            liveTransactionCount: sourceRows.count,
            liveFamilyCount: Set(sourceRows.map(\.familyID)).count,
            pairedTransferCount: sourceRows.reduce(into: 0) { count, row in
                if let transferID = row.transferID, pairedRowIDs.contains(transferID) {
                    count += 1
                }
            },
            digest: AccountLifecycleDigest.make(digestRows.flatMap(\.canonicalComponents))
        )
    }

    private static func accountLifecycleTransactionFacts(
        whereClause: String,
        arguments: StatementArguments,
        columns: Set<String>,
        transferColumn: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [AccountLifecycleTransactionFact] {
        let split = TransactionSplitQueryExpressions(columns: columns)
        let notes = database.column("notes", fallback: "NULL", columns: columns)
        return try Row.fetchAll(
            db,
            sql: """
                SELECT t.id,
                       \(split.qualifiedAccount) AS account_id,
                       \(split.qualifiedDate) AS date_value,
                       \(split.qualifiedAmount) AS amount_value,
                       \(split.qualifiedCategory) AS category_id,
                       \(split.qualifiedPayee) AS payee_id,
                       \(notes == "NULL" ? "NULL" : "t.\(notes)") AS notes_value,
                       \(split.qualifiedParentID) AS parent_id,
                       \(split.qualifiedIsParent) AS is_parent,
                       \(split.qualifiedIsChild) AS is_child,
                       t.\(database.quotedIdentifier(transferColumn)) AS transfer_id
                FROM transactions t
                WHERE \(database.predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND \(whereClause)
                ORDER BY t.id
                """,
            arguments: arguments
        ).compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else { return nil }
            return AccountLifecycleTransactionFact(
                id: id,
                accountID: SQLiteValueCoercion.lenientString(row["account_id"]) ?? "",
                date: SQLiteValueCoercion.lenientString(row["date_value"]) ?? "",
                amount: SQLiteValueCoercion.lenientString(row["amount_value"]) ?? "0",
                categoryID: SQLiteValueCoercion.lenientString(row["category_id"]) ?? "",
                payeeID: SQLiteValueCoercion.lenientString(row["payee_id"]) ?? "",
                notes: SQLiteValueCoercion.lenientString(row["notes_value"]) ?? "",
                parentID: (row["parent_id"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                isParent: SQLiteValueCoercion.lenientBool(row["is_parent"]),
                isChild: SQLiteValueCoercion.lenientBool(row["is_child"]),
                transferID: (row["transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    private static func accountLifecycleCategories(in database: isolated BudgetDatabase, db: Database) throws -> [AccountLifecycleCategory] {
        guard try database.tableExists("categories", db: db) else { return [] }
        let columns = try database.columnSet(for: "categories", db: db)
        guard columns.isSuperset(of: ["id", "name", "is_income"]) else { return [] }
        let hidden = database.column("hidden", fallback: "0", columns: columns)
        let order = columns.contains("sort_order") ? "sort_order, id" : "id"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(hidden) AS hidden
                FROM categories
                WHERE \(database.predicateForLiveRows(columns: columns))
                  AND COALESCE(is_income, 0) = 0
                ORDER BY \(order)
                """
        ).compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else { return nil }
            return AccountLifecycleCategory(
                id: id,
                name: row["name"] ?? "",
                isHidden: SQLiteValueCoercion.lenientBool(row["hidden"])
            )
        }
    }

    private static func accountLifecycleBankLink(
        accountID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> AccountLifecycleBankLink? {
        let columns = try database.columnSet(for: "accounts", db: db)
        let remote = database.column("account_id", fallback: "NULL", columns: columns)
        let source = database.column("account_sync_source", fallback: "NULL", columns: columns)
        let legacySource = database.column("bank_sync_source", fallback: "NULL", columns: columns)
        let bank = database.column("bank", fallback: "NULL", columns: columns)
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(remote) AS remote_id,
                       \(source) AS sync_source,
                       \(legacySource) AS legacy_sync_source,
                       \(bank) AS bank_id
                FROM accounts WHERE id = ?
                """,
            arguments: [accountID]
        ) else { return nil }
        let remoteID = accountLifecycleNonempty(row["remote_id"] as String?)
        let syncSource = accountLifecycleNonempty(row["sync_source"] as String?)
        let legacySyncSource = accountLifecycleNonempty(row["legacy_sync_source"] as String?)
        let bankID = accountLifecycleNonempty(row["bank_id"] as String?)
        guard remoteID != nil || syncSource != nil || legacySyncSource != nil || bankID != nil else {
            return nil
        }
        let provider: AccountLifecycleBankProvider
        switch syncSource {
        case let source where remoteID != nil
            && BankSyncLinkEligibility.isSimpleFIN(syncSource: source)
            && columns.isSuperset(of: accountLifecycleSimpleFINUnlinkColumns):
            provider = .simpleFIN
        case "goCardless": provider = .goCardless
        case "pluggyAI": provider = .pluggyAI
        case "akahu": provider = .akahu
        case "enableBanking": provider = .enableBanking
        default: provider = .unknown
        }
        let verifiedProvider = remoteID == nil ? AccountLifecycleBankProvider.unknown : provider
        return AccountLifecycleBankLink(
            provider: verifiedProvider,
            identity: AccountLifecycleBankLinkIdentity(
                remoteAccountID: remoteID,
                syncSource: syncSource ?? legacySyncSource,
                bankRowID: bankID
            )
        )
    }

    private static func accountLifecycleNonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func accountLifecycleInteger(_ value: DatabaseValueConvertible?) throws -> Int {
        guard let value else { return 0 }
        guard let exact = SQLiteValueCoercion.exactInt(value) else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }
        return exact
    }

    private static func accountLifecycleNegated(_ value: Int) throws -> Int {
        let (result, overflow) = 0.subtractingReportingOverflow(value)
        guard !overflow else { throw AccountLifecycleCommandError.invalidPreparedMutation }
        return result
    }

    private static func accountLifecycleScheduleFacts(
        accountID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> AccountLifecycleScheduleFacts {
        let schedulesExist = try database.tableExists("schedules", db: db)
        let rulesExist = try database.tableExists("rules", db: db)
        guard schedulesExist || rulesExist else {
            return scheduleFacts(components: [], inspectionAvailable: true)
        }
        guard schedulesExist, rulesExist else {
            return scheduleFacts(components: ["unavailable", schedulesExist ? "schedules" : "rules"])
        }

        let scheduleColumns = try database.columnSet(for: "schedules", db: db)
        let ruleColumns = try database.columnSet(for: "rules", db: db)
        guard scheduleColumns.isSuperset(of: ["id", "rule"]),
              ruleColumns.isSuperset(of: ["id", "conditions", "actions"]) else {
            return scheduleFacts(components: [
                "unavailable",
                scheduleColumns.sorted().joined(separator: ","),
                ruleColumns.sorted().joined(separator: ","),
            ])
        }

        let rows = try accountLifecycleScheduleRows(
            scheduleColumns: scheduleColumns,
            ruleColumns: ruleColumns,
            in: database,
            db: db
        )
        // A transfer into this account names its transfer payee, directly or through
        // `payee_mapping` after a payee merge. The resolved ids are digest facts, so a
        // merge that changes the references also changes the freshness check.
        let transferPayeeIDs = try accountLifecycleTransferPayeeIDs(accountID: accountID, in: database, db: db)
        let decoder = JSONDecoder()
        var references: [AccountScheduleReference] = []
        var components: [String] = ["transfer-payees"] + transferPayeeIDs.sorted()
        var inspectionAvailable = true
        for row in rows {
            let fact = AccountLifecycleScheduleRow(row: row)
            components.append(contentsOf: fact.canonicalComponents)
            guard let conditionsData = fact.conditions.data(using: .utf8),
                  let actionsData = fact.actions.data(using: .utf8) else {
                inspectionAvailable = false
                continue
            }
            let conditions: [RuleCondition]
            let actions: [RuleAction]
            do {
                conditions = try decoder.decode([RuleCondition].self, from: conditionsData)
                actions = try decoder.decode([RuleAction].self, from: actionsData)
            } catch {
                inspectionAvailable = false
                continue
            }
            guard !fact.ruleID.isEmpty,
                  fact.linkedRuleID == fact.ruleID,
                  actions.contains(where: { action in
                      action.operation == "link-schedule"
                          && action.value == .string(fact.scheduleID)
                  }) else {
                inspectionAvailable = false
                continue
            }
            guard fact.isLive else { continue }
            if conditions.contains(where: {
                accountLifecycleCondition($0, references: accountID, transferPayeeIDs: transferPayeeIDs)
            }) {
                references.append(AccountScheduleReference(
                    id: fact.scheduleID,
                    name: fact.name.isEmpty ? fact.scheduleID : fact.name
                ))
            }
        }
        return AccountLifecycleScheduleFacts(
            references: references,
            digest: AccountLifecycleDigest.make(components),
            inspectionAvailable: inspectionAvailable
        )
    }

    private static func accountLifecycleScheduleRows(
        scheduleColumns: Set<String>,
        ruleColumns: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [Row] {
        func schedule(_ name: String, fallback: String) -> String {
            scheduleColumns.contains(name) ? "s.\(database.quotedIdentifier(name))" : fallback
        }
        func rule(_ name: String, fallback: String) -> String {
            ruleColumns.contains(name) ? "r.\(database.quotedIdentifier(name))" : fallback
        }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT s.id AS schedule_id,
                       \(schedule("name", fallback: "s.id")) AS schedule_name,
                       s.rule AS schedule_rule,
                       \(schedule("active", fallback: "0")) AS schedule_active,
                       \(schedule("completed", fallback: "0")) AS schedule_completed,
                       \(schedule("posts_transaction", fallback: "0")) AS posts_transaction,
                       \(schedule("tombstone", fallback: "0")) AS schedule_tombstone,
                       r.id AS rule_id,
                       \(rule("stage", fallback: "NULL")) AS rule_stage,
                       r.conditions AS rule_conditions,
                       \(rule("conditions_op", fallback: "NULL")) AS conditions_op,
                       r.actions AS rule_actions,
                       \(rule("tombstone", fallback: "0")) AS rule_tombstone
                FROM schedules s
                LEFT JOIN rules r ON r.id = s.rule
                ORDER BY s.id
                """
        )
    }

    private static func accountLifecycleTransferPayeeIDs(
        accountID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Set<String> {
        guard try database.tableExists("payees", db: db) else { return [] }
        let columns = try database.columnSet(for: "payees", db: db)
        guard columns.contains("id"),
              let transferColumn = AccountColumns.transferPayee(in: columns) else {
            return []
        }
        let transferIDs = try Set(String.fetchAll(
            db,
            sql: """
                SELECT id FROM payees
                WHERE \(database.quotedIdentifier(transferColumn)) = ?
                  AND \(database.predicateForLiveRows(columns: columns))
                """,
            arguments: [accountID]
        ))
        guard !transferIDs.isEmpty else { return [] }
        let merged = try PayeeSQL.payeeMappingTargets(in: database, db: db).filter { transferIDs.contains($0.value) }.keys
        return transferIDs.union(merged)
    }

    private static func accountLifecycleCondition(
        _ condition: RuleCondition,
        references accountID: String,
        transferPayeeIDs: Set<String>
    ) -> Bool {
        switch condition.field {
        case "acct", "account":
            accountLifecycleJSONValue(condition.value, matches: { $0 == accountID })
        case "payee", "description":
            accountLifecycleJSONValue(condition.value, matches: transferPayeeIDs.contains)
        default:
            false
        }
    }

    private static func accountLifecycleJSONValue(
        _ value: RuleJSONValue,
        matches: (String) -> Bool
    ) -> Bool {
        switch value {
        case .string(let value): matches(value)
        case .array(let values): values.contains { accountLifecycleJSONValue($0, matches: matches) }
        case .object(let values): values.values.contains { accountLifecycleJSONValue($0, matches: matches) }
        case .null, .bool, .number: false
        }
    }

    private static func scheduleFacts(
        components: [String],
        inspectionAvailable: Bool = false
    ) -> AccountLifecycleScheduleFacts {
        AccountLifecycleScheduleFacts(
            references: [],
            digest: AccountLifecycleDigest.make(components),
            inspectionAvailable: inspectionAvailable
        )
    }
}

private let accountLifecycleSimpleFINUnlinkColumns: Set<String> = [
    "account_id",
    "account_sync_source",
    "bank",
    "balance_current",
    "balance_available",
    "balance_limit",
    "bank_sync_status",
]

private struct AccountLifecycleScheduleRow {
    let scheduleID: String
    let name: String
    let ruleID: String
    let isActive: Bool
    let isCompleted: Bool
    let postsTransaction: Bool
    let isTombstoned: Bool
    let linkedRuleID: String
    let stage: String
    let conditions: String
    let conditionsJoin: String
    let actions: String
    let ruleIsTombstoned: Bool

    init(row: Row) {
        scheduleID = row["schedule_id"] ?? ""
        name = row["schedule_name"] ?? ""
        ruleID = row["schedule_rule"] ?? ""
        isActive = SQLiteValueCoercion.lenientBool(row["schedule_active"])
        isCompleted = SQLiteValueCoercion.lenientBool(row["schedule_completed"])
        postsTransaction = SQLiteValueCoercion.lenientBool(row["posts_transaction"])
        isTombstoned = SQLiteValueCoercion.lenientBool(row["schedule_tombstone"])
        linkedRuleID = row["rule_id"] ?? ""
        stage = row["rule_stage"] ?? ""
        conditions = row["rule_conditions"] ?? ""
        conditionsJoin = row["conditions_op"] ?? ""
        actions = row["rule_actions"] ?? ""
        ruleIsTombstoned = SQLiteValueCoercion.lenientBool(row["rule_tombstone"])
    }

    var isLive: Bool {
        !isCompleted && !isTombstoned && !ruleIsTombstoned
    }

    var canonicalComponents: [String] {
        [
            scheduleID, name, ruleID, isActive ? "1" : "0", isCompleted ? "1" : "0",
            postsTransaction ? "1" : "0", isTombstoned ? "1" : "0", linkedRuleID,
            stage, conditions, conditionsJoin, actions, ruleIsTombstoned ? "1" : "0",
        ]
    }
}
