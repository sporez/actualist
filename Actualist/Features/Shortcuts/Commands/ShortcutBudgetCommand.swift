import Foundation

enum ShortcutBudgetCommand {
    @MainActor
    static func assign(
        categoryID: String,
        amountMinorUnits: Int,
        month: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        let prepared = try await session.prepare()
        let monthID = try await session.loadedMonth(preferred: month).selectedMonth
        _ = try await prepared.store.assignCategoryBudgetAndRefresh(
            categoryID: categoryID,
            budgeted: amountMinorUnits,
            budgetID: prepared.budgetID,
            month: monthID,
            didAssign: {}
        )
        session.recordSuccessfulWrite()
        return try await session.category(id: categoryID, month: monthID)
    }

    @MainActor
    static func add(
        categoryID: String,
        amountMinorUnits: Int,
        month: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        let current = try await session.category(id: categoryID, month: month)
        let currentBudgeted = try current.budgeted.map(ShortcutMoney.minorUnits(from:)) ?? 0
        return try await assign(
            categoryID: categoryID,
            amountMinorUnits: currentBudgeted + amountMinorUnits,
            month: month,
            session: session
        )
    }

    @MainActor
    static func move(
        fromCategoryID: String?,
        toCategoryID: String?,
        amountMinorUnits: Int,
        month: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        guard amountMinorUnits > 0 else {
            throw ShortcutsError.amountInvalid
        }
        let prepared = try await session.prepare()
        let monthID = try await session.loadedMonth(preferred: month).selectedMonth
        _ = try await prepared.store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: fromCategoryID,
                toCategoryID: toCategoryID,
                amount: amountMinorUnits
            ),
            budgetID: prepared.budgetID,
            month: monthID,
            didMove: {}
        )
        session.recordSuccessfulWrite()
        if let toCategoryID {
            return try await session.category(id: toCategoryID, month: monthID)
        }
        if let fromCategoryID {
            return try await session.category(id: fromCategoryID, month: monthID)
        }
        throw ShortcutsError.categoryNotFound
    }

    @MainActor
    static func applyTemplate(
        mode: BudgetTemplateApplicationMode,
        categoryID: String?,
        month: String?,
        session: ShortcutsBudgetSession
    ) async throws -> BudgetSummaryEntity {
        let prepared = try await session.prepare()
        let monthID = try await session.loadedMonth(preferred: month).selectedMonth
        let command = BudgetTemplateCommand(
            mode: mode,
            categoryIDs: categoryID.map { [$0] } ?? []
        )
        _ = try await prepared.store.applyBudgetTemplateAndRefresh(
            command: command,
            budgetID: prepared.budgetID,
            month: monthID,
            didApply: {}
        )
        session.recordSuccessfulWrite()
        return try await session.budgetSummary(month: monthID)
    }

    @MainActor
    static func setCarryover(
        categoryID: String,
        enabled: Bool,
        startMonth: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        let prepared = try await session.prepare()
        let monthID = try await session.loadedMonth(preferred: startMonth).selectedMonth
        _ = try await prepared.store.setCategoryCarryoverAndRefresh(
            categoryID: categoryID,
            carryover: enabled,
            budgetID: prepared.budgetID,
            startMonth: monthID,
            didSetCarryover: {}
        )
        session.recordSuccessfulWrite()
        return try await session.category(id: categoryID, month: monthID)
    }

    @MainActor
    static func createPayee(name: String, session: ShortcutsBudgetSession) async throws -> PayeeEntity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShortcutsError.payeeNotFound
        }
        let prepared = try await session.prepare()
        try await prepared.store.createPayeeAndRefresh(budgetID: prepared.budgetID, name: trimmed)
        session.recordSuccessfulWrite()
        let payees = try await session.payees(includeTransfers: false)
        if let created = payees.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return created
        }
        throw ShortcutsError.payeeNotFound
    }

    @MainActor
    static func createAccount(
        name: String,
        offBudget: Bool,
        session: ShortcutsBudgetSession
    ) async throws -> AccountEntity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShortcutsError.accountNotFound
        }
        let prepared = try await session.prepare()
        try await prepared.store.createAccountAndRefresh(
            budgetID: prepared.budgetID,
            name: trimmed,
            offbudget: offBudget
        )
        session.recordSuccessfulWrite()
        let accounts = try await session.accounts(includeClosed: true)
        if let created = accounts.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return created
        }
        throw ShortcutsError.accountNotFound
    }
}
