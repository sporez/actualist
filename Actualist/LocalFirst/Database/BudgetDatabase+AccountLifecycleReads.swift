import Foundation
import GRDB

extension BudgetDatabase {
    func accountLifecycleAccounts() throws -> [AccountLifecycleAccount] {
        try queue.read { db in
            try accountLifecycleAccounts(db: db)
        }
    }

    func accountEligibilitySnapshot() throws -> AccountEligibilitySnapshot {
        AccountEligibilitySnapshot(accounts: try accountLifecycleAccounts())
    }

    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest,
        localDay: AccountLifecycleDay = .localGregorian()
    ) throws -> AccountLifecycleReview {
        try queue.read { db in
            try accountLifecycleReview(
                request: request,
                localDay: localDay,
                db: db
            )
        }
    }

    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest,
        localDay: AccountLifecycleDay,
        db: Database
    ) throws -> AccountLifecycleReview {
        let accountID = request.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            throw AccountLifecycleCommandError.accountNotFound
        }

        let accounts = try accountLifecycleAccounts(db: db)
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AccountLifecycleCommandError.accountNotFound
        }
        let graph = try accountLifecycleTransactionGraph(accountID: accountID, db: db)
        let destinations = accounts
            .filter { !$0.isClosed && $0.id != accountID }
            .map {
                AccountLifecycleDestination(id: $0.id, name: $0.name, offBudget: $0.offBudget)
            }
        let categories = try accountLifecycleCategories(db: db)
        let bankLink = try accountLifecycleBankLink(accountID: accountID, db: db)
        let schedules = try accountLifecycleScheduleFacts(accountID: accountID, db: db)

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

    func accountLifecycleAccounts(db: Database) throws -> [AccountLifecycleAccount] {
        guard try tableExists("accounts", db: db) else {
            throw AccountLifecycleCommandError.missingAccountSchema
        }
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.isSuperset(of: ["id", "name", "offbudget", "closed"]) else {
            throw AccountLifecycleCommandError.missingAccountSchema
        }
        let groupID = column("account_group_id", fallback: "NULL", columns: columns)
        let order = columns.contains("sort_order") ? "sort_order, id" : "id"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, offbudget, closed, \(groupID) AS account_group_id
                FROM accounts
                WHERE \(predicateForLiveRows(columns: columns))
                ORDER BY \(order)
                """
        ).compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else { return nil }
            let rawGroupID = row["account_group_id"] as String?
            return AccountLifecycleAccount(
                id: id,
                name: row["name"] ?? "",
                offBudget: flexibleBool(row["offbudget"]),
                isClosed: flexibleBool(row["closed"]),
                accountGroupID: rawGroupID?.isEmpty == false ? rawGroupID : nil
            )
        }
    }
}

private extension BudgetDatabase {
    struct AccountLifecycleGraphFacts {
        let liveBalance: Int
        let liveTransactionCount: Int
        let liveFamilyCount: Int
        let pairedTransferCount: Int
        let digest: String
    }

    struct AccountLifecycleTransactionFact {
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

    func accountLifecycleTransactionGraph(
        accountID: String,
        db: Database
    ) throws -> AccountLifecycleGraphFacts {
        guard try tableExists("transactions", db: db) else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }
        let columns = try columnSet(for: "transactions", db: db)
        guard columns.contains("id"), columns.contains("date"), columns.contains("amount"),
              columns.contains("acct") || columns.contains("account") else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }
        guard let transferColumn = ["transferred_id", "transfer_id"].first(where: columns.contains) else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }

        let split = transactionSplitQueryExpressions(columns: columns)
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

    func accountLifecycleTransactionFacts(
        whereClause: String,
        arguments: StatementArguments,
        columns: Set<String>,
        transferColumn: String,
        db: Database
    ) throws -> [AccountLifecycleTransactionFact] {
        let split = transactionSplitQueryExpressions(columns: columns)
        let notes = column("notes", fallback: "NULL", columns: columns)
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
                       t.\(quotedIdentifier(transferColumn)) AS transfer_id
                FROM transactions t
                WHERE \(predicateForLiveRows(columns: columns, tableAlias: "t"))
                  AND \(whereClause)
                ORDER BY t.id
                """,
            arguments: arguments
        ).compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else { return nil }
            return AccountLifecycleTransactionFact(
                id: id,
                accountID: flexibleString(row["account_id"]) ?? "",
                date: flexibleString(row["date_value"]) ?? "",
                amount: flexibleString(row["amount_value"]) ?? "0",
                categoryID: flexibleString(row["category_id"]) ?? "",
                payeeID: flexibleString(row["payee_id"]) ?? "",
                notes: flexibleString(row["notes_value"]) ?? "",
                parentID: (row["parent_id"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                isParent: flexibleBool(row["is_parent"]),
                isChild: flexibleBool(row["is_child"]),
                transferID: (row["transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    func accountLifecycleCategories(db: Database) throws -> [AccountLifecycleCategory] {
        guard try tableExists("categories", db: db) else { return [] }
        let columns = try columnSet(for: "categories", db: db)
        guard columns.isSuperset(of: ["id", "name", "is_income"]) else { return [] }
        let hidden = column("hidden", fallback: "0", columns: columns)
        let order = columns.contains("sort_order") ? "sort_order, id" : "id"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(hidden) AS hidden
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                  AND COALESCE(is_income, 0) = 0
                ORDER BY \(order)
                """
        ).compactMap { row in
            guard let id = row["id"] as String?, !id.isEmpty else { return nil }
            return AccountLifecycleCategory(
                id: id,
                name: row["name"] ?? "",
                isHidden: flexibleBool(row["hidden"])
            )
        }
    }

    func accountLifecycleBankLink(
        accountID: String,
        db: Database
    ) throws -> AccountLifecycleBankLink? {
        let columns = try columnSet(for: "accounts", db: db)
        let remote = column("account_id", fallback: "NULL", columns: columns)
        let source = column("account_sync_source", fallback: "NULL", columns: columns)
        let legacySource = column("bank_sync_source", fallback: "NULL", columns: columns)
        let bank = column("bank", fallback: "NULL", columns: columns)
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

    func accountLifecycleNonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    func accountLifecycleInteger(_ value: DatabaseValueConvertible?) throws -> Int {
        guard let value else { return 0 }
        if let value = value as? Int { return value }
        if let value = value as? Int64, let exact = Int(exactly: value) { return exact }
        if let value = value as? Double, let exact = Int(exactly: value) { return exact }
        if let value = value as? String,
           let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        throw AccountLifecycleCommandError.missingTransactionSchema
    }

    func accountLifecycleNegated(_ value: Int) throws -> Int {
        let (result, overflow) = 0.subtractingReportingOverflow(value)
        guard !overflow else { throw AccountLifecycleCommandError.invalidPreparedMutation }
        return result
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
