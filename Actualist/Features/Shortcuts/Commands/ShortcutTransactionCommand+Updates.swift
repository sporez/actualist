import Foundation

extension ShortcutTransactionCommand {
    @MainActor
    static func update(_ input: UpdateInput, session: ShortcutsBudgetSession) async throws -> TransactionEntity {
        let prepared = try await session.prepare()
        let original = try await session.actualTransaction(id: input.transactionID)
        let draft = try await makeUpdateDraft(input, original: original, session: session)
        _ = try await prepared.store.updateTransactionAndRefresh(
            input.transactionID,
            with: draft,
            budgetID: prepared.budgetID,
            originalAccountID: original.account,
            originalMonth: original.date.actualYearMonth ?? draft.month.rawValue,
            didUpdate: {}
        )
        session.recordSuccessfulWrite()
        return try await session.transaction(id: input.transactionID)
    }

    @MainActor
    static func categorize(
        transactionID: String,
        categoryID: String,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionEntity {
        let prepared = try await session.prepare()
        let original = try await session.actualTransaction(id: transactionID)
        _ = try await prepared.store.categorizeTransactionAndRefresh(
            original,
            categoryID: categoryID,
            budgetID: prepared.budgetID,
            didUpdate: {}
        )
        session.recordSuccessfulWrite()
        return try await session.transaction(id: transactionID)
    }

    @MainActor
    static func setCleared(
        transactionID: String,
        cleared: Bool,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionEntity {
        try await update(
            UpdateInput(transactionID: transactionID, cleared: cleared),
            session: session
        )
    }

    @MainActor
    static func delete(transactionID: String, session: ShortcutsBudgetSession) async throws -> TransactionEntity {
        let prepared = try await session.prepare()
        let original = try await session.actualTransaction(id: transactionID)
        let snapshot = TransactionEntity.make(
            from: original,
            maps: try await nameMaps(for: original, session: session)
        )
        _ = try await prepared.store.deleteTransactionAndRefresh(
            original,
            budgetID: prepared.budgetID,
            didDelete: {}
        )
        session.recordSuccessfulWrite()
        guard let snapshot else {
            throw ShortcutsError.transactionNotFound
        }
        return snapshot
    }

    @MainActor
    private static func makeUpdateDraft(
        _ input: UpdateInput,
        original: ActualTransaction,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionDraft {
        let accountID = input.accountID ?? original.account
        let originalAmount = original.amount ?? 0
        let signedAmount: Int
        if let amount = input.amountMinorUnits {
            let amountCents = abs(amount)
            guard amountCents > 0 else {
                throw ShortcutsError.amountInvalid
            }
            let direction = input.direction ?? (originalAmount < 0 ? .spend : .inflow)
            signedAmount = direction == .inflow ? amountCents : -amountCents
        } else {
            signedAmount = originalAmount
        }
        let payeeName = resolvedPayeeName(
            id: input.payeeID ?? original.payee,
            name: input.payeeName ?? original.payeeName
        )
        let transfer = try await isTransferPayee(input.payeeID ?? original.payee, session: session)
        return TransactionDraft(
            accountID: accountID,
            date: input.date ?? original.date.actualDate ?? Date(),
            amountMinorUnits: signedAmount,
            payeeID: input.payeeID ?? original.payee,
            payeeName: payeeName,
            categoryID: input.categoryID ?? original.category,
            notes: input.notes.map(trimmed) ?? original.notes,
            cleared: input.cleared ?? original.cleared?.boolValue ?? false,
            isTransfer: transfer
        )
    }

    @MainActor
    private static func nameMaps(
        for transaction: ActualTransaction,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionNameMaps {
        let prepared = try await session.prepare()
        try await prepared.store.refreshAccountTransactions(
            budgetID: prepared.budgetID,
            accountID: transaction.account
        )
        if let loaded = prepared.store.cachedAccountTransactions(
            budgetID: prepared.budgetID,
            accountID: transaction.account
        ) {
            return TransactionNameMaps(loaded)
        }
        return TransactionNameMaps(
            accountNames: [:],
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: []
        )
    }
}
