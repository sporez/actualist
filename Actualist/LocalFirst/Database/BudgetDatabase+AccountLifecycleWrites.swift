import Foundation
import GRDB

enum AccountLifecycleMutationDecision: Equatable, Sendable {
    case apply(AccountLifecycleOutcome)
    case noChange(AccountLifecycleOutcome)
}

enum AccountLifecyclePreparedWrite: Equatable, Sendable {
    case apply(
        precondition: AccountLifecycleMutationPrecondition,
        messages: [ActualSyncDecodedMessage],
        outcome: AccountLifecycleOutcome
    )
    case noChange(AccountLifecycleOutcome)
}

extension BudgetDatabase {
    func prepareAccountRename(
        command: AccountRenameCommand,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> AccountLifecyclePreparedWrite {
        let command = try command.normalized()
        return try queue.read { db in
            let precondition = AccountLifecycleMutationPrecondition.rename(command)
            switch try validateAccountLifecycleMutation(precondition, db: db) {
            case .noChange(let outcome):
                return .noChange(outcome)
            case .apply(let outcome):
                let message = try builder.makeMessage(
                    dataset: "accounts",
                    row: command.accountID,
                    column: "name",
                    value: .string(command.newName)
                )
                return .apply(
                    precondition: precondition,
                    messages: [message],
                    outcome: outcome
                )
            }
        }
    }

    func prepareAccountReopen(
        command: AccountReopenCommand,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> AccountLifecyclePreparedWrite {
        let command = try command.normalized()
        return try queue.read { db in
            let precondition = AccountLifecycleMutationPrecondition.reopen(command)
            switch try validateAccountLifecycleMutation(precondition, db: db) {
            case .noChange(let outcome):
                return .noChange(outcome)
            case .apply(let outcome):
                let message = try builder.makeMessage(
                    dataset: "accounts",
                    row: command.accountID,
                    column: "closed",
                    value: .bool(false)
                )
                return .apply(
                    precondition: precondition,
                    messages: [message],
                    outcome: outcome
                )
            }
        }
    }

    func validateAccountLifecycleMutation(
        _ precondition: AccountLifecycleMutationPrecondition
    ) throws -> AccountLifecycleMutationDecision {
        try queue.read { db in
            try validateAccountLifecycleMutation(precondition, db: db)
        }
    }

    /// Integration contract: call this with the active `queue.write` database
    /// handle immediately before draft stamping/application. `.noChange` must
    /// return without advancing the clock or writing CRDT/outbox/action-log rows.
    func validateAccountLifecycleMutation(
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
}
