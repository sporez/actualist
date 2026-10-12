import Foundation

/// Assign and move-money gestures. Extracted from `LocalFirstActualStore+Mutations`
/// so recording these gestures in `actualist_action_log` (History, Phase 1) did
/// not push that file over the 800-line reassessment threshold. Each gesture
/// commits through `BudgetDatabase.commitUserAction` so the CRDT write and its
/// action-log row land atomically; the protocol witnesses record `.ui`, while
/// Shortcuts passes `.shortcuts`.
extension LocalFirstActualStore {
    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        try await assignCategoryBudgetAndRefresh(expectedMode: expectedMode,
            categoryID: categoryID,
            budgeted: budgeted,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didAssign: didAssign
        )
    }

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let mode = try await database.requireBudgetMode(expectedMode)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.assignCategoryBudgetMessages(
            categoryID: categoryID,
            budgeted: budgeted,
            month: month,
            builder: &builder
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

    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        try await moveMoneyAndRefresh(expectedMode: expectedMode,
            commands: [command],
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        try await moveMoneyAndRefresh(expectedMode: expectedMode,
            commands: [command],
            budgetID: budgetID,
            month: month,
            actionSource: actionSource,
            didMove: didMove
        )
    }

    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        try await moveMoneyAndRefresh(expectedMode: expectedMode,
            commands: commands,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let mode = try await database.requireBudgetMode(expectedMode)
        #if DEBUG
        await testSeams?.userActionBeforeCommitHook?()
        #endif
        _ = try await database.commitUserActionPlan(
            source: actionSource,
            expectedMode: mode
        ) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let resolved = try database.resolvedMoveMoneyCommands(commands, month: month, db: db)
            return UserActionPlan(
                drafts: try database.moveMoneyMessages(
                    commands: resolved,
                    month: month,
                    db: db,
                    builder: &builder
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
