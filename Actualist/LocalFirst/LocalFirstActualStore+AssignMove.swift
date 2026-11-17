import Foundation

/// Assign and move-money gestures. Extracted from `LocalFirstActualStore+Mutations`
/// so recording these gestures in `actualist_action_log` (History, Phase 1) did
/// not push that file over the 800-line reassessment threshold. Each gesture
/// commits through `BudgetDatabase.commitUserAction` so the CRDT write and its
/// action-log row land atomically; the default source is `.ui`, while
/// Shortcuts passes `.shortcuts`.
extension LocalFirstActualStore {
    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource = .ui,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await BudgetAssignmentSQL.assignCategoryBudgetMessages(
            categoryID: categoryID,
            budgeted: budgeted,
            month: month,
            builder: &builder,
            in: database
        )

        _ = try await database.commitUserAction(
            messages,
            descriptor: .assign(month: month, categoryID: categoryID, budgeted: budgeted),
            source: actionSource,
            expectedMode: mode
        )
        await didAssign()
        return await finishDurableBudgetWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            month: month
        )
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource = .ui,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        #if DEBUG
        await testSeams?.userActionBeforeCommitHook?()
        #endif
        _ = try await database.commitUserActionPlan(
            source: actionSource,
            expectedMode: mode
        ) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let resolved = try BudgetAssignmentSQL.resolvedMoveMoneyCommands(commands, month: month, in: database, db: db)
            return UserActionPlan(
                drafts: try BudgetAssignmentSQL.moveMoneyMessages(
                    commands: resolved,
                    month: month,
                    builder: &builder,
                    in: database,
                    db: db
                ),
                // A move limited to nothing records no History row; a transfer-available still writes its row.
                descriptor: resolved.allSatisfy { $0.amount == 0 } ? nil : .move(
                    month: month,
                    legs: resolved.filter { $0.amount > 0 }.map {
                        BudgetMoveLeg(
                            fromCategoryID: $0.fromCategoryID,
                            toCategoryID: $0.toCategoryID,
                            amount: $0.amount
                        )
                    }
                ),
                outcome: ()
            )
        }
        await didMove()
        return await finishDurableBudgetWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            month: month
        )
    }
}
