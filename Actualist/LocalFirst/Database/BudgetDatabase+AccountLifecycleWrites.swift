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
        try sessionWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
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
}
