import Foundation
import GRDB

private enum AccountLifecycleMutationDecision: Equatable, Sendable {
    case apply(AccountLifecycleOutcome)
    case noChange(AccountLifecycleOutcome)
}

extension BudgetDatabase {
    /// Rebuild the command's exact cell from fresh facts in the atomic commit.
    /// No preparation result, including an advisory no-op, authorizes a write.
    func commitAccountLifecycleMutation(
        _ precondition: AccountLifecycleMutationPrecondition,
        actionID: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> AccountLifecycleMutationResult {
        try Task.checkCancellation()
        return try commitLocalPlan(now: now) { db in
            let decision = try validateAccountLifecycleMutation(precondition, db: db)
            switch decision {
            case .noChange(let outcome):
                return LocalCommitPlan(
                    drafts: [], action: nil,
                    outcome: AccountLifecycleMutationResult.noChange(outcome)
                )
            case .apply(let outcome):
                var builder = LocalFirstSyncMessageBuilder()
                let column: String
                let value: LocalFirstSyncValue
                switch outcome.operation {
                case .rename:
                    column = "name"
                    value = .string(outcome.account.name)
                case .reopen:
                    column = "closed"
                    value = .bool(false)
                case .close, .delete:
                    throw AccountLifecycleCommandError.invalidPreparedMutation
                }
                let draft = try builder.makeMessage(
                    dataset: "accounts", row: outcome.account.id, column: column, value: value
                )
                return LocalCommitPlan(
                    drafts: [draft],
                    action: ActionLogCommit(
                        descriptor: .account(AccountActionDescriptor(
                            name: outcome.account.name,
                            offbudget: outcome.account.offBudget,
                            operation: outcome.operation
                        )),
                        source: .ui,
                        actionID: actionID
                    ),
                    outcome: AccountLifecycleMutationResult.applied(outcome)
                )
            }
        }.outcome
    }

    private func validateAccountLifecycleMutation(
        _ precondition: AccountLifecycleMutationPrecondition,
        db: Database
    ) throws -> AccountLifecycleMutationDecision {
        switch precondition {
        case .rename(let rawCommand):
            let command = try rawCommand.normalized()
            let accounts = try accountLifecycleAccounts(db: db)
            guard let current = accounts.first(where: { $0.id == command.accountID }) else {
                throw AccountLifecycleCommandError.accountNotFound
            }
            if current.name == command.newName {
                return .noChange(AccountLifecycleOutcome(operation: .rename, account: current))
            }
            guard current.name == command.expectedCurrentName else {
                throw AccountLifecycleCommandError.reviewChanged
            }
            if accounts.contains(where: {
                $0.id != command.accountID && $0.name == command.newName
            }) {
                throw AccountLifecycleCommandError.duplicateName(command.newName)
            }
            return .apply(AccountLifecycleOutcome(
                operation: .rename,
                account: AccountLifecycleAccount(
                    id: current.id,
                    name: command.newName,
                    offBudget: current.offBudget,
                    isClosed: current.isClosed,
                    accountGroupID: current.accountGroupID
                )
            ))

        case .reopen(let rawCommand):
            let command = try rawCommand.normalized()
            let accounts = try accountLifecycleAccounts(db: db)
            guard let current = accounts.first(where: { $0.id == command.accountID }) else {
                throw AccountLifecycleCommandError.accountNotFound
            }
            if !current.isClosed {
                return .noChange(AccountLifecycleOutcome(operation: .reopen, account: current))
            }
            guard command.expectedClosed else {
                throw AccountLifecycleCommandError.invalidPreparedMutation
            }
            return .apply(AccountLifecycleOutcome(
                operation: .reopen,
                account: AccountLifecycleAccount(
                    id: current.id,
                    name: current.name,
                    offBudget: current.offBudget,
                    isClosed: false,
                    accountGroupID: current.accountGroupID
                )
            ))
        }
    }

    func createAccountMessages(
        accountID: String,
        name: String,
        offbudget: Bool,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard !trimmedName.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account name")
        }

        return try queue.read { db in
            let accountColumns = try requiredColumns(
                table: "accounts",
                required: ["name"],
                db: db
            )
            if try rowExists(table: "accounts", rowID: trimmedAccountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("account already exists")
            }

            var messages: [ActualSyncDecodedMessage] = [
                try builder.makeMessage(
                    dataset: "accounts",
                    row: trimmedAccountID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if accountColumns.contains("offbudget") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "offbudget",
                        value: .bool(offbudget)
                    )
                )
            }
            if accountColumns.contains("closed") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "closed",
                        value: .bool(false)
                    )
                )
            }
            if accountColumns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }
            if accountColumns.contains("sort_order") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "sort_order",
                        value: .int(Int64(nextAccountSortOrder(offbudget: offbudget, db: db)))
                    )
                )
            }

            messages += try transferPayeeMessages(forAccountID: trimmedAccountID, db: db, builder: &builder)
            return messages
        }
    }

    private func nextAccountSortOrder(offbudget: Bool, db: Database) throws -> Int {
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.contains("sort_order") else {
            return Int(ActualSortOrder.increment)
        }
        let offbudgetColumn = column("offbudget", fallback: "0", columns: columns)
        let maxSortOrder = try Int.fetchOne(
            db,
            sql: "SELECT MAX(sort_order) FROM accounts WHERE \(offbudgetColumn) = ?",
            arguments: [offbudget ? 1 : 0]
        )
        return (maxSortOrder ?? 0) + Int(ActualSortOrder.increment)
    }

    private func transferPayeeMessages(
        forAccountID accountID: String,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard try tableExists("payees", db: db) else {
            return []
        }
        let payeeColumns = try requiredColumns(table: "payees", required: ["name"], db: db)
        let transferColumn = payeeColumns.contains("transfer_acct") ? "transfer_acct" : (
            payeeColumns.contains("transferAccount") ? "transferAccount" : nil
        )
        guard let transferColumn else {
            return []
        }

        let payeeID = UUID().uuidString
        var fields: [(String, LocalFirstSyncValue)] = [
            ("name", .string("")),
            (transferColumn, .string(accountID))
        ]
        if payeeColumns.contains("tombstone") {
            fields.append(("tombstone", .bool(false)))
        }
        if payeeColumns.contains("favorite") {
            fields.append(("favorite", .bool(false)))
        }
        if payeeColumns.contains("learn_categories") {
            fields.append(("learn_categories", .bool(false)))
        }
        if payeeColumns.contains("category") {
            fields.append(("category", .null))
        }

        var messages = try fields.map { field in
            try builder.makeMessage(dataset: "payees", row: payeeID, column: field.0, value: field.1)
        }

        if try tableExists("payee_mapping", db: db) {
            let mappingColumns = try requiredColumns(table: "payee_mapping", required: [], db: db)
            let targetColumn = try firstExistingColumn(
                ["targetId", "target_id"],
                in: mappingColumns,
                table: "payee_mapping"
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "payee_mapping",
                    row: payeeID,
                    column: targetColumn,
                    value: .string(payeeID)
                )
            )
        }
        return messages
    }
}
