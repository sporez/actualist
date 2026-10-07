import Foundation
import GRDB

struct AccountClosingTransferIDs: Hashable, Sendable {
    let source: String
    let destination: String

    static func random() -> Self {
        Self(source: UUID().uuidString, destination: UUID().uuidString)
    }
}

extension BudgetDatabase {
    func commitAccountLifecycleReview(
        _ reviewed: AccountLifecycleReview,
        actionID: String = UUID().uuidString,
        now: Date = Date(),
        localDay: @Sendable () -> AccountLifecycleDay = { .localGregorian() },
        transferIDs: AccountClosingTransferIDs = .random()
    ) throws -> AccountLifecycleCommitResult {
        try Task.checkCancellation()
        return try commitLocalPlan(now: now) { db in
            let request = AccountLifecycleReviewRequest(
                budgetID: reviewed.identity.budgetID,
                accountID: reviewed.identity.accountID,
                requestedAction: reviewed.identity.action
            )
            let fresh = try accountLifecycleReview(
                request: request,
                localDay: localDay(),
                db: db
            )
            guard fresh.identity == reviewed.identity,
                  fresh.resolvedAction == reviewed.resolvedAction,
                  fresh.blockers.isEmpty,
                  let action = fresh.resolvedAction else {
                return LocalCommitPlan(
                    drafts: [], action: nil,
                    outcome: AccountLifecycleCommitResult.reviewChanged(fresh)
                )
            }

            var builder = LocalFirstSyncMessageBuilder()
            var drafts: [ActualSyncDecodedMessage] = []
            if fresh.bankLink != nil {
                drafts += try makeBankSyncUnlinkMessages(
                    accountID: fresh.account.id,
                    builder: &builder,
                    db: db
                )
            }

            let operation: AccountLifecycleOperation
            var resultingAccount = fresh.account
            switch action {
            case .deleteEmptyAccount:
                operation = .delete
                drafts.append(try builder.makeMessage(
                    dataset: "accounts",
                    row: fresh.account.id,
                    column: "tombstone",
                    value: .bool(true)
                ))
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
                    transfer: transfer,
                    localDay: fresh.identity.localDay,
                    ids: transferIDs,
                    sortOrder: now.timeIntervalSince1970 * 1_000,
                    builder: &builder,
                    db: db
                )
            }

            let outcome = AccountLifecycleOutcome(
                operation: operation,
                account: resultingAccount
            )
            return LocalCommitPlan(
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

    private func accountClosedMessage(
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

    private func accountClosingTransferMessages(
        sourceAccountID: String,
        transfer: AccountClosingTransfer,
        localDay: AccountLifecycleDay,
        ids: AccountClosingTransferIDs,
        sortOrder: Double,
        builder: inout LocalFirstSyncMessageBuilder,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard transfer.date == localDay.isoDate,
              transfer.sourceAmount == -transfer.destinationAmount,
              transfer.sourceAmount != 0,
              ids.source != ids.destination else {
            throw AccountLifecycleCommandError.invalidPreparedMutation
        }
        let columns = try resolveTransactionRowColumns(db: db)
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
            db: db
        )
        let sourcePayeeID = try accountLifecycleTransferPayeeID(
            accountID: sourceAccountID,
            db: db
        )
        let source = try transactionRowMessages(
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
            columns: columns,
            builder: &builder
        )
        let destination = try transactionRowMessages(
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
            columns: columns,
            builder: &builder
        )
        return source + destination
    }

    private func accountLifecycleTransferPayeeID(
        accountID: String,
        db: Database
    ) throws -> String {
        guard try tableExists("payees", db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing payees table")
        }
        let columns = try columnSet(for: "payees", db: db)
        guard let transferColumn = ["transfer_acct", "transferAccount"]
            .first(where: columns.contains) else {
            throw LocalFirstError.invalidLocalWrite("missing transfer payee account column")
        }
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM payees
                WHERE \(quotedIdentifier(transferColumn)) = ?
                  AND \(predicateForLiveRows(columns: columns))
                ORDER BY id
                """,
            arguments: [accountID]
        )
        guard ids.count == 1, let id = ids.first, !id.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing or duplicate transfer payee")
        }
        return id
    }
}
