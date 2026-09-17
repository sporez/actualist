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
    ) async throws -> LoadedBudgetMonth {
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
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
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
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
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
    ) async throws -> LoadedBudgetMonth {
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
    ) async throws -> LoadedBudgetMonth {
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
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let mode = try await database.requireBudgetMode(expectedMode)
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
            source: actionSource,
            expectedMode: mode
        )
        await didMove()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }
}
