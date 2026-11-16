import Foundation
import GRDB

struct AccountClosingTransferIDs: Hashable, Sendable {
    let source: String
    let destination: String

    static func random() -> Self {
        Self(source: UUID().uuidString, destination: UUID().uuidString)
    }
}

private enum AccountLifecycleMutationDecision: Equatable, Sendable {
    case apply(AccountLifecycleOutcome)
    case noChange(AccountLifecycleOutcome)
}

enum AccountLifecycleCommitSQL {
    static func commitAccountLifecycleReview(
        _ reviewed: AccountLifecycleReview,
        actionID: String = UUID().uuidString,
        now: Date = Date(),
        localDay: @Sendable () -> AccountLifecycleDay = { .localGregorian() },
        transferIDs: AccountClosingTransferIDs = .random(),
        in database: isolated BudgetDatabase
    ) throws -> AccountLifecycleCommitResult {
        try Task.checkCancellation()
        return try database.commitLocalPlan(now: now) { db in
            let request = AccountLifecycleReviewRequest(
                budgetID: reviewed.identity.budgetID,
                accountID: reviewed.identity.accountID,
                requestedAction: reviewed.identity.action
            )
            let fresh = try AccountLifecycleReviewSQL.accountLifecycleReview(
                request: request,
                localDay: localDay(),
                in: database,
                db: db
            )
            guard fresh.identity == reviewed.identity,
                  fresh.resolvedAction == reviewed.resolvedAction,
                  fresh.blockers.isEmpty,
                  let action = fresh.resolvedAction else {
                return BudgetDatabase.LocalCommitPlan(
                    drafts: [], action: nil,
                    outcome: AccountLifecycleCommitResult.reviewChanged(fresh)
                )
            }

            var builder = LocalFirstSyncMessageBuilder()
            var drafts: [ActualSyncDecodedMessage] = []
            if fresh.bankLink != nil {
                drafts += try BankSyncLinkSQL.makeBankSyncUnlinkMessages(
                    accountID: fresh.account.id,
                    builder: &builder,
                    in: database,
                    db: db
                )
            }

            let operation: AccountLifecycleOperation
            var resultingAccount = fresh.account
            switch action {
            case .deleteEmptyAccount:
                operation = .delete
                drafts.append(try builder.tombstone(dataset: "accounts", row: fresh.account.id))
            case .closeAtZero:
                operation = .close
                resultingAccount = AccountLifecycleAccount(
                    id: fresh.account.id,
                    name: fresh.account.name,
                    offBudget: fresh.account.offBudget,
                    isClosed: true,
                    accountGroupID: fresh.account.accountGroupID
                )
                drafts.append(try accountClosedMessage(
                    accountID: fresh.account.id,
                    builder: &builder
                ))
            case .closeWithTransfer(let transfer):
                operation = .close
                resultingAccount = AccountLifecycleAccount(
                    id: fresh.account.id,
                    name: fresh.account.name,
                    offBudget: fresh.account.offBudget,
                    isClosed: true,
                    accountGroupID: fresh.account.accountGroupID
                )
                drafts.append(try accountClosedMessage(
                    accountID: fresh.account.id,
                    builder: &builder
                ))
                drafts += try accountClosingTransferMessages(
                    sourceAccountID: fresh.account.id,
                    sourceOffBudget: fresh.account.offBudget,
                    transfer: transfer,
                    localDay: fresh.identity.localDay,
                    ids: transferIDs,
                    sortOrder: now.timeIntervalSince1970 * 1_000,
                    builder: &builder,
                    in: database,
                    db: db
                )
            }

            let outcome = AccountLifecycleOutcome(
                operation: operation,
                account: resultingAccount
            )
            return BudgetDatabase.LocalCommitPlan(
                drafts: drafts,
                action: ActionLogCommit(
                    descriptor: .account(AccountActionDescriptor(
                        name: resultingAccount.name,
                        offbudget: resultingAccount.offBudget,
                        operation: operation
                    )),
                    source: .ui,
                    actionID: actionID
                ),
                outcome: AccountLifecycleCommitResult.applied(outcome)
            )
        }.outcome
    }

    private static func accountClosedMessage(
        accountID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> ActualSyncDecodedMessage {
        try builder.makeMessage(
            dataset: "accounts",
            row: accountID,
            column: "closed",
            value: .bool(true)
        )
    }

    private static func accountClosingTransferMessages(
        sourceAccountID: String,
        sourceOffBudget: Bool,
        transfer: AccountClosingTransfer,
        localDay: AccountLifecycleDay,
        ids: AccountClosingTransferIDs,
        sortOrder: Double,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard transfer.date == localDay.isoDate,
              transfer.sourceAmount == -transfer.destinationAmount,
              transfer.sourceAmount != 0,
              ids.source != ids.destination else {
            throw AccountLifecycleCommandError.invalidPreparedMutation
        }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        guard columns.transferID != nil,
              columns.isParent != nil,
              columns.isChild != nil,
              columns.sortOrder != nil,
              columns.hasNotes,
              columns.hasCleared,
              columns.hasReconciled,
              columns.hasTombstone,
              columns.hasParentID else {
            throw AccountLifecycleCommandError.missingTransactionSchema
        }
        let destinationPayeeID = try accountLifecycleTransferPayeeID(
            accountID: transfer.destinationAccountID,
            in: database,
            db: db
        )
        let sourcePayeeID = try accountLifecycleTransferPayeeID(
            accountID: sourceAccountID,
            in: database,
            db: db
        )
        // Actual clears the source category only for a transfer between accounts on the same side
        // of the budget; crossing sides leaves an unassigned category unwritten.
        let destinationOffBudget = try AccountLifecycleReviewSQL.accountLifecycleAccounts(in: database, db: db)
            .first { $0.id == transfer.destinationAccountID }?.offBudget ?? sourceOffBudget
        let source = try columns.rowMessages(
            rowID: ids.source,
            accountID: sourceAccountID,
            dateValue: localDay.transactionDate,
            amountMinorUnits: transfer.sourceAmount,
            payeeID: destinationPayeeID,
            categoryID: transfer.categoryID,
            notes: transfer.notes,
            cleared: true,
            reconciled: false,
            isParent: false,
            parentID: nil,
            isChild: false,
            transferID: ids.destination,
            sortOrder: sortOrder,
            builder: &builder,
            cells: .inserted(clearsCategory: sourceOffBudget == destinationOffBudget)
        )
        let destination = try columns.rowMessages(
            rowID: ids.destination,
            accountID: transfer.destinationAccountID,
            dateValue: localDay.transactionDate,
            amountMinorUnits: transfer.destinationAmount,
            payeeID: sourcePayeeID,
            categoryID: nil,
            notes: transfer.notes,
            cleared: false,
            reconciled: false,
            isParent: false,
            parentID: nil,
            isChild: false,
            transferID: ids.source,
            sortOrder: sortOrder,
            builder: &builder
        )
        return source + destination
    }

    private static func accountLifecycleTransferPayeeID(
        accountID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> String {
        guard try database.tableExists("payees", db: db) else {
            throw LocalFirstError.schemaUnavailable("missing payees table")
        }
        let columns = try database.columnSet(for: "payees", db: db)
        guard let transferColumn = AccountColumns.transferPayee(in: columns) else {
            throw LocalFirstError.invalidLocalWrite("missing transfer payee account column")
        }
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM payees
                WHERE \(database.quotedIdentifier(transferColumn)) = ?
                  AND \(database.predicateForLiveRows(columns: columns))
                ORDER BY id
                """,
            arguments: [accountID]
        )
        guard ids.count == 1, let id = ids.first, !id.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing or duplicate transfer payee")
        }
        return id
    }

    /// Rebuild the command's exact cell from fresh facts in the atomic commit.
    /// No preparation result, including an advisory no-op, authorizes a write.
    static func commitAccountLifecycleMutation(
        _ precondition: AccountLifecycleMutationPrecondition,
        actionID: String = UUID().uuidString,
        now: Date = Date(),
        in database: isolated BudgetDatabase
    ) throws -> AccountLifecycleMutationResult {
        try Task.checkCancellation()
        return try database.commitLocalPlan(now: now) { db in
            let decision = try validateAccountLifecycleMutation(precondition, in: database, db: db)
            switch decision {
            case .noChange(let outcome):
                return BudgetDatabase.LocalCommitPlan(
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
                return BudgetDatabase.LocalCommitPlan(
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

    private static func validateAccountLifecycleMutation(
        _ precondition: AccountLifecycleMutationPrecondition,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> AccountLifecycleMutationDecision {
        switch precondition {
        case .rename(let rawCommand):
            let command = try rawCommand.normalized()
            let accounts = try AccountLifecycleReviewSQL.accountLifecycleAccounts(in: database, db: db)
            guard let current = accounts.first(where: { $0.id == command.accountID }) else {
                throw AccountLifecycleCommandError.accountNotFound
            }
            if current.name == command.newName {
                return .noChange(AccountLifecycleOutcome(operation: .rename, account: current))
            }
            guard current.name == command.expectedCurrentName else {
                throw AccountLifecycleCommandError.reviewChanged
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
            let accounts = try AccountLifecycleReviewSQL.accountLifecycleAccounts(in: database, db: db)
            guard let current = accounts.first(where: { $0.id == command.accountID }) else {
                throw AccountLifecycleCommandError.accountNotFound
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
}
