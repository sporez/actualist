import Foundation

extension LocalFirstActualStore {
    /// Actual's running-balance preferences (`RunningBalancePreference`), so
    /// the setting follows the budget to both web layouts. The current column
    /// layout is read inside the commit. Last write wins; History records nothing.
    func setShowsRunningBalance(budgetID: String, accountID: String, enabled: Bool) async throws {
        let database = try requireDatabase(for: budgetID)
        let written = try await database.commitSyncedPreferences(
            reading: RunningBalancePreference.keys(accountID: accountID)
        ) { stored in
            RunningBalancePreference.writes(
                enabled: enabled,
                accountID: accountID,
                current: RunningBalancePreference.values(stored, accountID: accountID)
            )
        }
        guard written else { return }
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        }
    }


    // MARK: - Account mutations / server operations

    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {
        try await createAccountAndRefresh(
            budgetID: budgetID,
            name: name,
            offbudget: offbudget,
            actionSource: .ui
        )
    }

    func createAccountAndRefresh(
        budgetID: String,
        name: String,
        offbudget: Bool,
        actionSource: BudgetActionSource
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        let accountID = UUID().uuidString
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await AccountSQL.createAccountMessages(
            accountID: accountID,
            name: name,
            offbudget: offbudget,
            builder: &builder,
            in: database
        )

        _ = try await database.commitUserAction(
            messages,
            descriptor: .account(AccountActionDescriptor(name: name, offbudget: offbudget)),
            source: actionSource
        )
        try await finishCommittedAccountWrite(database: database, budgetID: budgetID)
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await BudgetAssignmentSQL.categoryCarryoverMessages(
            categoryID: categoryID,
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: Self.categoryCarryoverHorizonMonth(startMonth: startMonth),
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
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await BudgetAssignmentSQL.allExpenseCategoryCarryoverMessages(
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: Self.categoryCarryoverHorizonMonth(startMonth: startMonth),
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
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
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
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
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
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
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

    func applyBudgetTemplateAndRefresh(reviewRevision: BudgetTemplateReviewRevision? = nil,
        expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let mode = try await BudgetModeSQL.requireBudgetMode(expectedMode, in: database)
        #if DEBUG
        await testSeams?.userActionBeforeCommitHook?()
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
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        let database = try requireDatabase(for: budgetID)
        return try await RulePreviewSQL.previewRules(for: draft, in: database)
    }
}
