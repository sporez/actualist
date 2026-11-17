import Foundation

/// The budget month on the store: assign and move money, category carryover
/// and visibility, and applying a template, each with the reload that follows,
/// plus the month selection and mode reads. The money gestures commit with
/// their action-log row in one transaction; the default source is `.ui`, while
/// Shortcuts passes `.shortcuts`. The store owns it; the month cache and its
/// read machinery stay on the store, which the commit tail, notes, launch and
/// Shortcuts also use.
@MainActor
final class BudgetWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func budgetModeIdentity(budgetID: String) async throws -> BudgetModeIdentity? {
        let database = try store.requireDatabase(for: budgetID)
        return try await BudgetModeSQL.fetchBudgetModeIdentity(in: database)
    }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        let months = try await store.availableMonths(budgetID: budgetID)
        let tracking = try await LaunchSignpost.measure(LaunchStage.budgetModeLookup) {
            try await store.requireDatabase(for: budgetID).isTrackingBudget()
        }
        let selected = tracking || months.contains(preferredMonth) ? preferredMonth : (months.last ?? preferredMonth)
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: selected)
    }

    func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth {
        try await store.budgetMonth(budgetID: budgetID, selectedMonth: selectedMonth)
    }

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource = .ui,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
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
        return await store.finishDurableBudgetWrite(
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
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
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
        return await store.finishDurableBudgetWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            month: month
        )
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try store.requireDatabase(for: budgetID)
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await BudgetAssignmentSQL.categoryCarryoverMessages(
            categoryID: categoryID,
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: BudgetWorkflows.categoryCarryoverHorizonMonth(startMonth: startMonth),
            builder: &builder,
            in: database
        )

        _ = try await database.commitUserAction(
            messages,
            descriptor: .carryover(CarryoverActionDescriptor(
                startMonth: startMonth,
                after: carryover,
                categoryCount: 1
            )),
            source: .ui,
            expectedMode: mode
        )
        await didSetCarryover()
        try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        let database = try store.requireDatabase(for: budgetID)
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await BudgetAssignmentSQL.allExpenseCategoryCarryoverMessages(
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: BudgetWorkflows.categoryCarryoverHorizonMonth(startMonth: startMonth),
            builder: &builder,
            in: database
        )

        if !messages.isEmpty {
            _ = try await database.commitUserAction(
                messages,
                descriptor: .carryover(CarryoverActionDescriptor(
                    startMonth: startMonth,
                    after: carryover,
                    categoryCount: 0
                )),
                source: .ui,
                expectedMode: mode
            )
        }
        try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await CategorySQL.setCategoryHiddenMessages(
            categoryID: categoryID,
            hidden: hidden,
            builder: &builder,
            in: database
        )
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        await didUpdate()
        try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await CategorySQL.setCategoryGroupHiddenMessages(
            groupID: groupID,
            hidden: hidden,
            builder: &builder,
            in: database
        )
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        await didUpdate()
        try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    // Actual loads budget months through a year past the current month (`createAllBudgets` over
    // `getBudgetRange`) and applies carryover through them.
    static func categoryCarryoverHorizonMonth(
        startMonth: String,
        now: Date = Date()
    ) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let horizonDate = calendar.date(byAdding: .month, value: 12, to: now) ?? now
        return max(startMonth, YearMonth(date: horizonDate).rawValue)
    }

    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await applyBudgetTemplateAndRefresh(reviewRevision: nil,
            expectedMode: expectedMode,
            command: command,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didApply: didApply
        )
    }

    func applyReviewedBudgetTemplateAndRefresh(
        reviewRevision: BudgetTemplateReviewRevision,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard reviewRevision.month == month else {
            throw LocalFirstError.budgetTemplateReviewStale
        }
        return try await applyBudgetTemplateAndRefresh(
            reviewRevision: reviewRevision,
            expectedMode: nil,
            command: command,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didApply: didApply
        )
    }

    func applyBudgetTemplateAndRefresh(reviewRevision: BudgetTemplateReviewRevision? = nil,
        expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try store.requireDatabase(for: budgetID)
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
        #endif
        _ = try await database.commitUserActionPlan(
            source: actionSource,
            expectedMode: reviewRevision?.modeIdentity ?? mode,
            expectedTemplateReviewRevision: reviewRevision
        ) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let result = try TemplateApplySQL.budgetTemplateApply(
                command: command,
                month: month,
                builder: &builder,
                in: database,
                db: db
            )
            // A goal-only or orphan-cleanup write moved no money; History
            // records money-flow gestures only.
            return UserActionPlan(
                drafts: result.messages,
                descriptor: result.assignments.isEmpty
                    ? nil
                    : .template(month: month, mode: command.mode, assignments: result.assignments),
                outcome: ()
            )
        }
        await didApply()
        try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: month)
    }
}

extension BudgetWorkflows: BudgetRepositoryProtocol {}
