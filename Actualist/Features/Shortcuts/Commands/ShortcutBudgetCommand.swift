import Foundation

enum ShortcutBudgetCommand {
    @MainActor
    static func assign(
        categoryID: String,
        amountMinorUnits: Int,
        month: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        return try await session.withExclusiveWrite { prepared in
            try await assignLocked(
                categoryID: categoryID,
                amountMinorUnits: amountMinorUnits,
                month: month,
                prepared: prepared,
                session: session
            )
        }
    }

    @MainActor
    static func add(
        categoryID: String,
        amountMinorUnits: Int,
        month: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        return try await session.withExclusiveWrite { prepared in
            let current = try await session.category(id: categoryID, month: month)
            let currentBudgeted = try current.budgeted.map {
                try ShortcutMoney.minorUnits(from: $0, currency: prepared.currency)
            } ?? 0
            return try await assignLocked(
                categoryID: categoryID,
                amountMinorUnits: currentBudgeted + amountMinorUnits,
                month: month,
                prepared: prepared,
                session: session
            )
        }
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
        guard fromCategoryID != nil || toCategoryID != nil else {
            throw ShortcutsError.categoryNotFound
        }
        return try await session.withExclusiveWrite { prepared in
            let monthID = try await session.loadedMonth(preferred: month).selectedMonth
            _ = try await prepared.store.moveMoneyAndRefresh(
                command: BudgetMoveMoneyCommand(
                    fromCategoryID: fromCategoryID,
                    toCategoryID: toCategoryID,
                    amount: amountMinorUnits
                ),
                budgetID: prepared.budgetID,
                month: monthID,
                actionSource: .shortcuts,
                didMove: {}
            )
            session.recordSuccessfulWrite()
            if let toCategoryID {
                return try await session.category(id: toCategoryID, month: monthID)
            }
            return try await session.category(id: fromCategoryID ?? "", month: monthID)
        }
    }

    @MainActor
    static func applyTemplate(
        mode: BudgetTemplateApplicationMode,
        categoryID: String?,
        month: String?,
        session: ShortcutsBudgetSession
    ) async throws -> BudgetSummaryEntity {
        return try await session.withExclusiveWrite { prepared in
            let monthID = try await session.loadedMonth(preferred: month).selectedMonth
            let command = BudgetTemplateCommand(
                mode: mode,
                categoryIDs: categoryID.map { [$0] } ?? []
            )
            _ = try await prepared.store.applyBudgetTemplateAndRefresh(
                command: command,
                budgetID: prepared.budgetID,
                month: monthID,
                actionSource: .shortcuts,
                didApply: {}
            )
            session.recordSuccessfulWrite()
            return try await session.budgetSummary(month: monthID)
        }
    }

    @MainActor
    static func setCarryover(
        categoryID: String,
        enabled: Bool,
        startMonth: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        return try await session.withExclusiveWrite { prepared in
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
    }

    @MainActor
    static func createPayee(name: String, session: ShortcutsBudgetSession) async throws -> PayeeEntity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShortcutsError.invalidName
        }
        return try await session.withExclusiveWrite { prepared in
            let before = Set(try await session.payees(includeTransfers: false).map(\.id))
            try await prepared.store.createPayeeAndRefresh(budgetID: prepared.budgetID, name: trimmed)
            session.recordSuccessfulWrite()
            let after = try await session.payees(includeTransfers: false)
            if let created = after.first(where: { !before.contains($0.id) }) {
                return created
            }
            throw ShortcutsError.payeeNotFound
        }
    }

    @MainActor
    static func createAccount(
        name: String,
        offBudget: Bool,
        session: ShortcutsBudgetSession
    ) async throws -> AccountEntity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShortcutsError.invalidName
        }
        return try await session.withExclusiveWrite { prepared in
            let before = Set(try await session.accounts(includeClosed: true).map(\.id))
            try await prepared.store.createAccountAndRefresh(
                budgetID: prepared.budgetID,
                name: trimmed,
                offbudget: offBudget,
                actionSource: .shortcuts
            )
            session.recordSuccessfulWrite()
            let after = try await session.accounts(includeClosed: true)
            if let created = after.first(where: { !before.contains($0.id) }) {
                return created
            }
            throw ShortcutsError.accountNotFound
        }
    }

    @MainActor
    private static func assignLocked(
        categoryID: String,
        amountMinorUnits: Int,
        month: String?,
        prepared: PreparedBudget,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity {
        let monthID = try await session.loadedMonth(preferred: month).selectedMonth
        _ = try await prepared.store.assignCategoryBudgetAndRefresh(
            categoryID: categoryID,
            budgeted: amountMinorUnits,
            budgetID: prepared.budgetID,
            month: monthID,
            actionSource: .shortcuts,
            didAssign: {}
        )
        session.recordSuccessfulWrite()
        return try await session.category(id: categoryID, month: monthID)
    }
}
