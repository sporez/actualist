import Foundation

enum ShortcutTransactionCommand {
    struct LogInput: Sendable {
        var amountMinorUnits: Int
        var direction: ShortcutTransactionDirection
        var accountID: String? = nil
        var payeeID: String? = nil
        var payeeName: String? = nil
        var categoryID: String? = nil
        var notes: String? = nil
        var date: Date? = nil
        var cleared: Bool = false
    }

    struct UpdateInput: Sendable {
        var transactionID: String
        var amountMinorUnits: Int? = nil
        var direction: ShortcutTransactionDirection? = nil
        var accountID: String? = nil
        var payeeID: String? = nil
        var payeeName: String? = nil
        var categoryID: String? = nil
        var notes: String? = nil
        var date: Date? = nil
        var cleared: Bool? = nil
    }

    @MainActor
    static func log(_ input: LogInput, session: ShortcutsBudgetSession) async throws -> TransactionEntity {
        return try await session.withExclusiveWrite { prepared in
            try await logLocked(input, session: session, prepared: prepared)
        }
    }

    @MainActor
    static func transfer(
        fromAccountID: String,
        toAccountID: String,
        amountMinorUnits: Int,
        date: Date?,
        notes: String?,
        session: ShortcutsBudgetSession
    ) async throws -> TransactionEntity {
        return try await session.withExclusiveWrite { prepared in
            try await transferLocked(
                fromAccountID: fromAccountID,
                toAccountID: toAccountID,
                amountMinorUnits: amountMinorUnits,
                date: date,
                notes: notes,
                session: session,
                prepared: prepared
            )
        }
    }

    @MainActor
    static func importFromText(_ text: String, session: ShortcutsBudgetSession) async throws -> TransactionEntity {
        let parsed = try ShortcutTextImportParser.parse(text)
        return try await session.withExclusiveWrite { prepared in
            if parsed.direction == .transfer {
                let source = try await resolveAccount(
                    text: parsed.accountText,
                    required: true,
                    session: session
                )
                let destination = try await resolveAccount(
                    text: parsed.destinationAccountText,
                    required: true,
                    session: session
                )
                guard let source, let destination else {
                    throw ShortcutsError.transferDestinationMissing
                }
                return try await transferLocked(
                    fromAccountID: source.id,
                    toAccountID: destination.id,
                    amountMinorUnits: parsed.amountMinorUnits,
                    date: parsed.date,
                    notes: parsed.notes,
                    session: session,
                    prepared: prepared
                )
            }

            let account = try await resolveAccount(text: parsed.accountText, required: false, session: session)
            let category = try await resolveCategory(text: parsed.categoryText, session: session)
            return try await logLocked(
                LogInput(
                    amountMinorUnits: parsed.amountMinorUnits,
                    direction: parsed.direction ?? .spend,
                    accountID: account?.id,
                    payeeID: nil,
                    payeeName: parsed.payeeText,
                    categoryID: category?.id,
                    notes: parsed.notes,
                    date: parsed.date,
                    cleared: false
                ),
                session: session,
                prepared: prepared
            )
        }
    }

    static func uniqueMatch<Item>(
        in items: [Item],
        named name: (Item) -> String,
        query: String,
        notFound: ShortcutsError
    ) throws -> Item {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            throw notFound
        }
        let exact = items.filter { name($0).localizedCaseInsensitiveCompare(needle) == .orderedSame }
        if exact.count == 1 {
            return exact[0]
        }
        if exact.count > 1 {
            throw ShortcutsError.ambiguousMatch
        }
        let prefix = items.filter {
            name($0).localizedLowercase.hasPrefix(needle.localizedLowercase)
        }
        if prefix.count == 1 {
            return prefix[0]
        }
        if prefix.count > 1 {
            throw ShortcutsError.ambiguousMatch
        }
        throw notFound
    }

    @MainActor
    private static func logLocked(
        _ input: LogInput,
        session: ShortcutsBudgetSession,
        prepared: PreparedBudget
    ) async throws -> TransactionEntity {
        let draft = try await makeLogDraft(input, session: session, prepared: prepared)
        let result = try await prepared.store.createTransactionAndRefresh(
            draft,
            budgetID: prepared.budgetID,
            didCreate: {}
        )
        session.recordSuccessfulWrite()
        guard let transactionID = result.changed.transactions.first else {
            throw ShortcutsError.transactionNotFound
        }
        return try await session.transaction(id: transactionID)
    }

    @MainActor
    private static func transferLocked(
        fromAccountID: String,
        toAccountID: String,
        amountMinorUnits: Int,
        date: Date?,
        notes: String?,
        session: ShortcutsBudgetSession,
        prepared: PreparedBudget
    ) async throws -> TransactionEntity {
        guard fromAccountID != toAccountID else {
            throw ShortcutsError.transferDestinationMissing
        }
        let destination = try await session.account(id: toAccountID, includeClosed: false)
        let transferPayee = try await session.transferPayee(forAccountID: destination.id)
        return try await logLocked(
            LogInput(
                amountMinorUnits: amountMinorUnits,
                direction: .spend,
                accountID: fromAccountID,
                payeeID: transferPayee.id,
                payeeName: transferPayee.name,
                categoryID: nil,
                notes: notes,
                date: date,
                cleared: false
            ),
            session: session,
            prepared: prepared
        )
    }

    @MainActor
    private static func makeLogDraft(
        _ input: LogInput,
        session: ShortcutsBudgetSession,
        prepared: PreparedBudget
    ) async throws -> TransactionDraft {
        let accountID = try resolvedAccountID(input.accountID, prepared: prepared)
        let account = try await session.account(id: accountID, includeClosed: true)
        if account.closed {
            throw ShortcutsError.accountClosed
        }
        let amountCents = abs(input.amountMinorUnits)
        guard amountCents > 0 else {
            throw ShortcutsError.amountInvalid
        }
        let transfer = try await isTransferPayee(input.payeeID, session: session)
        let omitCategory = account.offBudget || transfer
        var categoryID = omitCategory ? nil : input.categoryID
        let payeeName = resolvedPayeeName(id: input.payeeID, name: input.payeeName)
        var draft = TransactionDraft(
            accountID: accountID,
            date: input.date ?? Date(),
            amountMinorUnits: input.direction == .inflow ? amountCents : -amountCents,
            payeeID: input.payeeID,
            payeeName: payeeName,
            categoryID: categoryID,
            notes: trimmed(input.notes),
            cleared: input.cleared,
            isTransfer: transfer
        )
        let preview = try await prepared.store.previewRules(for: draft, budgetID: prepared.budgetID)
        if preview.deletesTransaction {
            throw ShortcutsError.writeFailed
        }
        if categoryID == nil, !omitCategory {
            categoryID = preview.categoryID
            if categoryID != nil {
                draft = TransactionDraft(
                    accountID: draft.accountID,
                    date: draft.date,
                    amountMinorUnits: draft.amountMinorUnits,
                    payeeID: draft.payeeID,
                    payeeName: draft.payeeName,
                    categoryID: categoryID,
                    notes: draft.notes,
                    cleared: draft.cleared,
                    isTransfer: draft.isTransfer,
                    importedPayee: draft.importedPayee,
                    reconciled: draft.reconciled,
                    isParent: draft.isParent,
                    splits: draft.splits
                )
            }
        }
        return draft
    }

    @MainActor
    private static func resolvedAccountID(_ accountID: String?, prepared: PreparedBudget) throws -> String {
        if let accountID {
            return accountID
        }
        guard let defaultAccountID = prepared.defaultAccountID else {
            throw ShortcutsError.defaultAccountMissing
        }
        return defaultAccountID
    }

    @MainActor
    private static func resolveAccount(
        text: String?,
        required: Bool,
        session: ShortcutsBudgetSession
    ) async throws -> AccountEntity? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if required {
                throw ShortcutsError.accountNotFound
            }
            return nil
        }
        let accounts = try await session.accounts(includeClosed: false)
        return try uniqueMatch(
            in: accounts,
            named: \.name,
            query: text,
            notFound: .accountNotFound
        )
    }

    @MainActor
    private static func resolveCategory(
        text: String?,
        session: ShortcutsBudgetSession
    ) async throws -> CategoryEntity? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let categories = try await session.categories(includeHidden: false, includeIncome: true)
        return try uniqueMatch(
            in: categories,
            named: \.name,
            query: text,
            notFound: .categoryNotFound
        )
    }

    @MainActor
    static func isTransferPayee(_ payeeID: String?, session: ShortcutsBudgetSession) async throws -> Bool {
        guard let payeeID else {
            return false
        }
        return try await session.payees(includeTransfers: true).contains { $0.id == payeeID && $0.isTransfer }
    }

    static func resolvedPayeeName(id: String?, name: String?) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }
        if id != nil {
            return "Payee"
        }
        return "Unknown"
    }

    static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

