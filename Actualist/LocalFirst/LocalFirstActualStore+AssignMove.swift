import Foundation

/// Assign and move-money gestures. Extracted from `LocalFirstActualStore+Mutations`
/// so recording these gestures in `actualist_action_log` (History, Phase 1) did
/// not push that file over the 800-line reassessment threshold. Each gesture
/// commits through `BudgetDatabase.commitUserAction` so the CRDT write and its
/// action-log row land atomically; the protocol witnesses record `.ui`, while
/// Shortcuts passes `.shortcuts`.
extension LocalFirstActualStore {
    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await assignCategoryBudgetAndRefresh(
            categoryID: categoryID,
            budgeted: budgeted,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didAssign: didAssign
        )
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
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
            source: actionSource
        )
        await didAssign()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(
            commands: [command],
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(
            commands: [command],
            budgetID: budgetID,
            month: month,
            actionSource: actionSource,
            didMove: didMove
        )
    }

    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(
            commands: commands,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.moveMoneyMessages(
            commands: commands,
            month: month,
            builder: &builder
        )

        _ = try await database.commitUserAction(
            messages,
            descriptor: .move(
                month: month,
                legs: commands.map {
                    BudgetMoveLeg(
                        fromCategoryID: $0.fromCategoryID,
                        toCategoryID: $0.toCategoryID,
                        amount: $0.amount
                    )
                }
            ),
            source: actionSource
        )
        await didMove()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }
}
