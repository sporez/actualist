import Foundation

extension ShortcutTransactionCommand {
    @MainActor
    static func update(_ input: UpdateInput, session: ShortcutsBudgetSession) async throws -> TransactionEntity {
        return try await session.withExclusiveWrite { prepared in
            try await updateLocked(input, session: session, prepared: prepared)
        }
    }

    @MainActor
    static func categorize(
        transactionID: String,
        categoryID: String,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionEntity {
        return try await session.withExclusiveWrite { prepared in
            let original = try await session.actualTransaction(id: transactionID)
            try rejectSplitMutation(original)
            _ = try await prepared.store.categorizeTransactionAndRefresh(
                original,
                categoryID: categoryID,
                budgetID: prepared.budgetID,
                didUpdate: {}
            )
            session.recordSuccessfulWrite()
            return try await session.transaction(id: transactionID)
        }
    }

    @MainActor
    static func setCleared(
        transactionID: String,
        cleared: Bool,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionEntity {
        return try await session.withExclusiveWrite { prepared in
            try await updateLocked(
                UpdateInput(transactionID: transactionID, cleared: cleared),
                session: session,
                prepared: prepared
            )
        }
    }

    @MainActor
    private static func updateLocked(
        _ input: UpdateInput,
        session: ShortcutsBudgetSession,
        prepared: PreparedBudget
    ) async throws -> TransactionEntity {
        let original = try await session.actualTransaction(id: input.transactionID)
        try rejectSplitChild(original)
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
    static func delete(transactionID: String, session: ShortcutsBudgetSession) async throws -> TransactionEntity {
        return try await session.withExclusiveWrite { prepared in
            let original = try await session.actualTransaction(id: transactionID)
            try rejectSplitChild(original)
            let snapshot = TransactionEntity.make(
                from: original,
                maps: try await session.nameMaps(for: original)
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
    }

    @MainActor
    private static func makeUpdateDraft(
        _ input: UpdateInput,
        original: ActualTransaction,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionDraft {
        if isSplitParent(original) {
            return try makePreservingSplitDraft(input, original: original)
        }

        let originalIsTransfer = try await isTransferPayee(original.payee, session: session)
        if originalIsTransfer {
            try await rejectTransferStructureChange(input, original: original, session: session)
        }

        let accountID = input.accountID ?? original.account
        if let accountID = input.accountID {
            let account = try await session.account(id: accountID, includeClosed: true)
            if account.closed {
                throw ShortcutsError.accountClosed
            }
        }
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
            isTransfer: originalIsTransfer || transfer
        )
    }

    private static func makePreservingSplitDraft(
        _ input: UpdateInput,
        original: ActualTransaction
    ) throws -> TransactionDraft {
        guard original.subtransactions.count >= 2 else {
            throw ShortcutsError.unsupportedSplit
        }
        if input.amountMinorUnits != nil
            || input.direction != nil
            || input.accountID != nil
            || input.payeeID != nil
            || input.payeeName != nil
            || input.categoryID != nil {
            throw ShortcutsError.unsupportedSplit
        }

        return TransactionDraft(
            accountID: original.account,
            date: input.date ?? original.date.actualDate ?? Date(),
            amountMinorUnits: original.amount ?? 0,
            payeeID: original.payee,
            payeeName: resolvedPayeeName(id: original.payee, name: original.payeeName),
            categoryID: original.category,
            notes: input.notes.map(trimmed) ?? original.notes,
            cleared: input.cleared ?? original.cleared?.boolValue ?? false,
            isTransfer: false,
            isParent: true,
            splits: original.subtransactions.map { child in
                TransactionSplitDraft(
                    id: child.id,
                    categoryID: child.category,
                    categoryName: nil,
                    amountMinorUnits: child.amount ?? 0
                )
            }
        )
    }

    @MainActor
    private static func rejectTransferStructureChange(
        _ input: UpdateInput,
        original: ActualTransaction,
        session: ShortcutsBudgetSession
    ) async throws {
        if let payeeID = input.payeeID, payeeID != original.payee {
            let stillTransfer = try await isTransferPayee(payeeID, session: session)
            if !stillTransfer {
                throw ShortcutsError.unsupportedTransfer
            }
        }
        if input.payeeName != nil, input.payeeID == nil {
            throw ShortcutsError.unsupportedTransfer
        }
        if input.categoryID != nil {
            throw ShortcutsError.unsupportedTransfer
        }
    }

    private static func rejectSplitChild(_ transaction: ActualTransaction) throws {
        if transaction.isChild || (transaction.parentID?.isEmpty == false) {
            throw ShortcutsError.unsupportedSplit
        }
    }

    private static func rejectSplitMutation(_ transaction: ActualTransaction) throws {
        try rejectSplitChild(transaction)
        if isSplitParent(transaction) {
            throw ShortcutsError.unsupportedSplit
        }
    }

    private static func isSplitParent(_ transaction: ActualTransaction) -> Bool {
        transaction.isParent || transaction.subtransactions.count >= 2
    }
}
