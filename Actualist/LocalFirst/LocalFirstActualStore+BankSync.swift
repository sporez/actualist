import Foundation

/// SimpleFIN bank-sync orchestration (plan Phase 3): download → normalize →
/// rule projection → reconciler plan → review DTO → confirm → CRDT writes.
/// The UI (Phase 4) only renders `BankSyncReview.AccountPlan` and calls the
/// intents here; all payload math, state, and write orchestration live in
/// this file and `BudgetDatabase+BankSync.swift`.
extension LocalFirstActualStore {
    enum BankSyncStoreError: LocalizedError, Equatable {
        case staleGeneration
        case notLinked
        case notSimpleFINLinked

        var errorDescription: String? {
            switch self {
            case .staleGeneration:
                return "This bank sync review is stale. Download again."
            case .notLinked:
                return "This account is not linked to a bank."
            case .notSimpleFINLinked:
                return "Only SimpleFIN-linked accounts can sync here."
            }
        }
    }

    // MARK: - Server capability

    func bankSyncSupport(budgetID: String) async throws -> SimpleFINServerSupport {
        let context = try bankSyncContext(budgetID: budgetID)
        return try await context.transport.simpleFINStatus(token: context.token)
    }

    // MARK: - Device-claim provider (plan Phase 5)

    /// Where downloads come from: the Actual server's SimpleFIN routes, or
    /// (fallback) the SimpleFIN bridge directly with a device-claimed key.
    enum BankSyncProvider {
        case server(transport: any SimpleFINServerTransport, token: String)
        case device(SimpleFINBridgeClient)

        var isDevice: Bool {
            if case .device = self { return true }
            return false
        }

        func remoteAccounts() async throws -> [SimpleFINRemoteAccount] {
            switch self {
            case .server(let transport, let token):
                return try await transport.simpleFINAccounts(token: token) ?? []
            case .device(let client):
                return try await client.remoteAccounts()
            }
        }

        func transactions(
            accountIDs: [String],
            startDates: [String]
        ) async throws -> SimpleFINTransactionsResponse {
            switch self {
            case .server(let transport, let token):
                // nil = routes unsupported; an empty answer drives the
                // existing account-missing handling downstream.
                return try await transport.simpleFINTransactions(
                    token: token,
                    accountIDs: accountIDs,
                    startDates: startDates
                ) ?? SimpleFINTransactionsResponse(downloads: [:], errorType: nil, errorCode: nil)
            case .device(let client):
                return try await client.transactions(accountIDs: accountIDs, startDates: startDates)
            }
        }
    }

    /// `makeBankSyncProvider`: server `configured == true` wins; otherwise a
    /// device-claimed bridge key; otherwise the server transport so its
    /// status classification surfaces as before. An unreachable server (a
    /// connection-level transport failure on the status probe) falls back to
    /// the device key when one exists and rethrows otherwise.
    func bankSyncProvider(budgetID: String) async throws -> BankSyncProvider {
        _ = try requireDatabase(for: budgetID)
        do {
            let context = try bankSyncContext(budgetID: budgetID)
            let support = try await context.transport.simpleFINStatus(token: context.token)
            if support == .configured {
                return .server(transport: context.transport, token: context.token)
            }
            if let device = try? bankSyncDeviceClient() {
                return .device(device)
            }
            return .server(transport: context.transport, token: context.token)
        } catch let error as ActualAPIError {
            if case .transport = error, let device = try? bankSyncDeviceClient() {
                return .device(device)
            }
            throw error
        }
    }

    /// Whether a device-claimed SimpleFIN access key is stored. Device-wide:
    /// not budget-scoped, survives budget switches, cleared only by erase
    /// (sign-out) or an explicit disconnect on the Bank Sync screen.
    func hasBankSyncDeviceKey() -> Bool {
        !keychain.readSimpleFINAccessURL().isEmpty
    }

    /// Claims a pasted setup token once and stores the access key in the
    /// Keychain. The key is never returned to callers or logged.
    func claimBankSyncDeviceToken(_ setupToken: String) async throws {
        let claimed = try await SimpleFINBridgeClient.claim(setupToken: setupToken)
        let base = claimed.baseURL.absoluteString
        let scheme = "https://"
        let hostAndPath = base.lowercased().hasPrefix(scheme) ? base.dropFirst(scheme.count) : base[...]
        let accessURL = "https://\(claimed.username):\(claimed.password)@\(hostAndPath)"
        try keychain.saveSimpleFINAccessURL(accessURL)
    }

    /// Disconnect forgets the device key only. Links and transactions stay.
    func forgetBankSyncDeviceKey() throws {
        try keychain.removeSimpleFINAccessURL()
    }

    private func bankSyncDeviceClient() throws -> SimpleFINBridgeClient {
        let stored = keychain.readSimpleFINAccessURL()
        guard !stored.isEmpty else {
            throw SimpleFINBridgeError.invalidAccessURL
        }
        let credentials = try SimpleFINBridgeCredentials.accessCredentials(fromClaimBody: stored)
        let baseURL = try SimpleFINBridgeCredentials.baseURL(fromClaimBody: stored)
        return SimpleFINBridgeClient(
            baseURL: baseURL,
            username: credentials.username,
            password: credentials.password
        )
    }

    /// Remote SimpleFIN-side accounts through the resolved provider
    /// (server first, device-claimed bridge fallback).
    func bankSyncRemoteAccounts(budgetID: String) async throws -> [SimpleFINRemoteAccount] {
        let provider = try await bankSyncProvider(budgetID: budgetID)
        return try await provider.remoteAccounts()
    }

    // MARK: - Link / unlink

    /// loot-core `linkSimpleFinAccount` shape, applied locally as CRDT
    /// messages. Does not auto-download — the deliberate divergence from
    /// Actual web (Decision Log): link first, explicit Sync after.
    func linkBankAccount(
        _ localAccountID: String,
        to remote: SimpleFINRemoteAccount,
        budgetID: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.makeBankSyncLinkMessages(
            accountID: localAccountID,
            remote: remote,
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        try await reloadAfterAccountMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    /// loot-core `unlinkAccount`: clear the link columns, leave transactions.
    func unlinkBankAccount(_ localAccountID: String, budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.makeBankSyncUnlinkMessages(
            accountID: localAccountID,
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        bankSyncGenerationByAccount[localAccountID] = nil
        try await reloadAfterAccountMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    // MARK: - Download → review plan

    /// Downloads one linked account, projects rules, matches, and returns the
    /// review plan. Writes nothing. Bumps the account's generation so a later
    /// apply with an older plan is refused.
    func downloadBankSyncPlan(accountID: String, budgetID: String) async throws -> BankSyncReview.AccountPlan {
        let database = try requireDatabase(for: budgetID)
        let provider = try await bankSyncProvider(budgetID: budgetID)

        guard let linked = try await database.bankSyncLinkedAccounts()
            .first(where: { $0.id == accountID }) else {
            throw BankSyncStoreError.notLinked
        }
        guard linked.syncSource == "simpleFin" else {
            throw BankSyncStoreError.notSimpleFINLinked
        }

        let currency: BudgetCurrency
        if let cached = currencyByBudget[budgetID] {
            currency = cached
        } else {
            currency = try await database.fetchBudgetCurrency()
        }
        let oldestDayID = try await database.bankSyncOldestLiveTransactionDayID(accountID: accountID)
        let startDate = BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: oldestDayID)
        let response = try await provider.transactions(
            accountIDs: [linked.remoteAccountID],
            startDates: [startDate]
        )

        var download = response.downloads[linked.remoteAccountID]
        if download == nil, response.errorCode == nil {
            // Null / absent account entry: the bridge had nothing for this
            // account, which the durable vocabulary records as account-missing.
            download = SimpleFINAccountDownload(
                transactions: [],
                startingBalance: nil,
                errorType: nil,
                errorCode: "ACCOUNT_MISSING"
            )
        }
        if response.hasWholeRequestError, download?.errorCode == nil {
            download = SimpleFINAccountDownload(
                transactions: download?.transactions ?? [],
                startingBalance: download?.startingBalance,
                errorType: response.errorType,
                errorCode: response.errorCode
            )
        }
        let resolvedDownload = try Unwrap(download)

        let normalized = try await normalizeDownload(
            resolvedDownload,
            accountID: accountID,
            currency: currency,
            database: database
        )

        // Opening-balance current balance: prefer the raw decimal `balance`
        // from /simplefin/accounts (parsed with the budget currency scale);
        // fall back to the server-computed `startingBalance` only for a
        // confirmed 2-decimal currency; otherwise no opening balance is
        // proposed. Never `parseInt(balance.replace('.', ''))`.
        let remoteAccounts = try await provider.remoteAccounts()
        let rawBalance = remoteAccounts.first { $0.accountID == linked.remoteAccountID }?.balance
        var currentBalanceMinorUnits: Int?
        if let parsed = BankSyncAmounts.minorUnits(fromDecimal: rawBalance, currency: currency) {
            currentBalanceMinorUnits = parsed
        } else if currency.decimalPlaces == 2 {
            currentBalanceMinorUnits = resolvedDownload.startingBalance
        }
        let openingBalance: BankSyncReconciliation.OpeningBalance?
        if let currentBalanceMinorUnits {
            openingBalance = BankSyncReconciliation.openingBalance(
                currentBalanceMinorUnits: currentBalanceMinorUnits,
                candidateAmounts: normalized.candidateAmounts,
                earliestDayID: normalized.earliestDayID,
                accountHadLiveTransactions: try await database.bankSyncAccountHasLiveTransactions(accountID: accountID)
            )
        } else {
            openingBalance = nil
        }

        let existing = try await database.bankSyncExistingRows(
            accountID: accountID,
            window: Self.monthWidenedWindow(candidateDayIDs: normalized.dayIDs)
        )
        let plan = BankSyncReconciliation.plan(candidates: normalized.projectedCandidates, existing: existing)

        let generation = (bankSyncGenerationByAccount[accountID] ?? 0) + 1
        bankSyncGenerationByAccount[accountID] = generation

        return BankSyncReview.AccountPlan(
            accountID: accountID,
            remoteAccountID: linked.remoteAccountID,
            durableStatus: ActualBankSyncDurableStatus.from(errorCode: resolvedDownload.errorCode),
            inserts: plan.inserts,
            updates: plan.entries.compactMap { entry in
                if case .update(let update) = entry { return update }
                return nil
            },
            unchangedCount: plan.entries.reduce(0) { count, entry in
                if case .unchanged = entry { return count + 1 }
                return count
            },
            problems: normalized.problems,
            openingBalance: openingBalance,
            generation: generation
        )
    }

    // MARK: - Apply

    /// Writes a confirmed plan: opening balance, match updates (with the
    /// split-parent cleared cascade), inserts oldest-first, category
    /// learning, then the `last_sync` / `bank_sync_status` stamp. One commit
    /// for the plan, one for category learning (mirroring wallet import).
    func applyBankSyncPlan(
        _ plan: BankSyncReview.AccountPlan,
        budgetID: String
    ) async throws -> BankSyncReview.ApplyResult {
        let database = try requireDatabase(for: budgetID)
        guard bankSyncGenerationByAccount[plan.accountID] == plan.generation else {
            throw BankSyncStoreError.staleGeneration
        }

        var builder = LocalFirstSyncMessageBuilder()
        var messages: [ActualSyncDecodedMessage] = []
        var resolvedPayeeIDs: [String: String] = [:]
        var categorizedIDs = Set<String>()
        var insertedCount = 0
        var updatedCount = 0
        let sortOrderBase = Date().timeIntervalSince1970 * 1_000

        if let openingBalance = plan.openingBalance {
            let onBudget = !(try await database.bankSyncLinkedAccounts()
                .first { $0.id == plan.accountID }?.offbudget ?? false)
            messages.append(contentsOf: try await database.makeBankSyncOpeningBalanceMessages(
                accountID: plan.accountID,
                openingBalance: openingBalance,
                onBudget: onBudget,
                sortOrder: sortOrderBase,
                builder: &builder
            ))
        }

        let existingByID = Dictionary(
            uniqueKeysWithValues: try await database.bankSyncExistingRows(
                accountID: plan.accountID,
                window: 0...99_999_999
            ).map { ($0.id, $0) }
        )
        for update in plan.updates {
            guard let existing = existingByID[update.existingID] else {
                throw LocalFirstError.invalidLocalWrite("missing matched transaction")
            }
            messages.append(contentsOf: try await database.makeBankSyncMatchUpdateMessages(
                update: update,
                existing: existing,
                builder: &builder
            ))
            updatedCount += 1
        }

        var monthIDs = Set<String>()
        for (index, candidate) in plan.inserts.enumerated() {
            let transactionID = UUID().uuidString
            let payeeResolution = try await resolveBankSyncInsertPayee(
                candidate: candidate,
                resolvedPayeeIDs: &resolvedPayeeIDs,
                database: database,
                builder: &builder
            )
            let draft = try bankSyncInsertDraft(
                candidate: candidate,
                accountID: plan.accountID,
                payeeID: payeeResolution.payeeID,
                sortOrder: sortOrderBase + Double(index + 1)
            )
            let transactionMessages = draft.isSplit
                ? try await database.createSplitTransactionMessages(
                    draft: draft,
                    parentTransactionID: transactionID,
                    payeeID: payeeResolution.payeeID,
                    builder: &builder
                )
                : try await database.createSimpleTransactionMessages(
                    draft,
                    transactionID: transactionID,
                    payeeID: payeeResolution.payeeID,
                    builder: &builder
                )
            messages.append(contentsOf: payeeResolution.messages)
            messages.append(contentsOf: transactionMessages)
            monthIDs.insert(draft.month.rawValue)
            if draft.categoryID != nil {
                categorizedIDs.insert(transactionID)
            }
            insertedCount += 1
        }

        // Stamp after the writes: status always, last_sync only when the
        // download succeeded (a failed status leaves last_sync untouched).
        let stampEpoch: Int64? = plan.durableStatus == .ok
            ? Int64(Date().timeIntervalSince1970 * 1_000)
            : nil
        messages.append(contentsOf: try await database.makeBankSyncStampMessages(
            accountID: plan.accountID,
            lastSyncEpochMilliseconds: stampEpoch,
            status: plan.durableStatus,
            builder: &builder
        ))

        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        let learningMessages = try await database.categoryLearningRuleMessages(
            changedTransactionIDs: categorizedIDs,
            builder: &builder
        )
        if !learningMessages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(learningMessages)
            rulesByBudget[budgetID] = try await database.fetchRules()
            payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
                .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
        }

        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: [plan.accountID],
            monthIDs: Array(monthIDs)
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return BankSyncReview.ApplyResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            openingBalanceInserted: plan.openingBalance != nil
        )
    }

    // MARK: - Normalization

    private struct NormalizedDownload {
        var projectedCandidates: [BankSyncReconciliation.Candidate] = []
        var problems: [BankSyncReview.Problem] = []
        var candidateAmounts: [Int] = []
        var dayIDs: [String] = []
        var earliestDayID: String?
    }

    /// Per-account normalization + rule projection. `candidateAmounts`
    /// deliberately sums every normalized provider candidate before
    /// rule-driven suppression — the bank balance reflects all of them
    /// (opening-balance contract).
    private func normalizeDownload(
        _ download: SimpleFINAccountDownload,
        accountID: String,
        currency: BudgetCurrency,
        database: BudgetDatabase
    ) async throws -> NormalizedDownload {
        var normalized = NormalizedDownload()
        for transaction in download.transactions {
            let problemID = transaction.id
            guard let amountMinorUnits = BankSyncAmounts.minorUnits(
                fromDecimal: transaction.amount,
                currency: currency
            ) else {
                normalized.problems.append(BankSyncReview.Problem(
                    remoteTransactionID: problemID,
                    message: "Unreadable amount"
                ))
                continue
            }
            guard let dayID = transaction.dateUnixSeconds.map(BankSyncAmounts.dayID(fromUnixSeconds:)) else {
                normalized.problems.append(BankSyncReview.Problem(
                    remoteTransactionID: problemID,
                    message: "Unreadable date"
                ))
                continue
            }
            // The bank balance for opening-balance math comes from the raw
            // decimal balance on /simplefin/accounts, not the transactions
            // payload; see the download plan assembly above.
            guard let candidate = try await bankSyncCandidate(
                from: transaction,
                amountMinorUnits: amountMinorUnits,
                dayID: dayID,
                accountID: accountID,
                database: database
            ) else {
                continue
            }
            normalized.candidateAmounts.append(amountMinorUnits)
            normalized.dayIDs.append(dayID)
            if normalized.earliestDayID == nil || dayID < normalized.earliestDayID! {
                normalized.earliestDayID = dayID
            }
            if let projected = BankSyncReconciliation.applyingRulePreview(
                try await database.previewRules(for: bankSyncPreviewDraft(
                    candidate: candidate,
                    accountID: accountID,
                    dayID: dayID
                )),
                to: candidate
            ) {
                normalized.projectedCandidates.append(projected)
            }
        }
        return normalized
    }

    private func bankSyncCandidate(
        from transaction: SimpleFINRemoteTransaction,
        amountMinorUnits: Int,
        dayID: String,
        accountID: String,
        database: BudgetDatabase
    ) async throws -> BankSyncReconciliation.Candidate? {
        let payeeName = transaction.payeeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPayeeID: String?
        if let payeeName {
            resolvedPayeeID = try await database.bankSyncResolvedPayeeID(name: payeeName)
        } else {
            resolvedPayeeID = nil
        }
        return BankSyncReconciliation.Candidate(
            financialID: transaction.id,
            dayID: dayID,
            amountMinorUnits: amountMinorUnits,
            payeeID: resolvedPayeeID,
            payeeName: payeeName,
            notes: transaction.notes.map(BankSyncReconciliation.escapedNotes),
            categoryID: nil,
            cleared: transaction.booked ?? true,
            importedPayee: payeeName
        )
    }

    /// Rule-preview draft: raw values so payee-name and amount conditions
    /// evaluate against what the bank sent, before the matcher sees it.
    private func bankSyncPreviewDraft(
        candidate: BankSyncReconciliation.Candidate,
        accountID: String,
        dayID: String
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: accountID,
            date: BankSyncAmounts.date(fromDayID: dayID) ?? Date(timeIntervalSince1970: 0),
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: nil,
            payeeName: candidate.payeeName ?? "",
            categoryID: nil,
            notes: candidate.notes,
            cleared: candidate.cleared,
            isTransfer: false
        )
    }

    private func bankSyncInsertDraft(
        candidate: BankSyncReconciliation.Candidate,
        accountID: String,
        payeeID: String,
        sortOrder: Double
    ) throws -> TransactionDraft {
        var draft = TransactionDraft(
            accountID: accountID,
            date: try Unwrap(BankSyncAmounts.date(fromDayID: candidate.dayID)),
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: payeeID,
            payeeName: candidate.payeeName ?? "",
            categoryID: candidate.categoryID,
            notes: candidate.notes,
            cleared: candidate.cleared,
            isTransfer: false
        )
        draft.importedPayee = candidate.importedPayee
        draft.importedID = candidate.financialID
        draft.sortOrder = sortOrder
        if candidate.isSplit {
            let splitTotal = candidate.splits.reduce(0) { $0 + $1.amountMinorUnits }
            guard splitTotal == candidate.amountMinorUnits else {
                throw LocalFirstError.invalidLocalWrite("split amounts do not sum to the transaction total")
            }
            draft.splits = candidate.splits.map {
                TransactionSplitDraft(id: nil, categoryID: $0.categoryID, categoryName: nil, amountMinorUnits: $0.amountMinorUnits)
            }
        }
        return draft
    }

    private func resolveBankSyncInsertPayee(
        candidate: BankSyncReconciliation.Candidate,
        resolvedPayeeIDs: inout [String: String],
        database: BudgetDatabase,
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> (payeeID: String, messages: [ActualSyncDecodedMessage]) {
        if let selectedPayeeID = candidate.payeeID, !selectedPayeeID.isEmpty {
            return (selectedPayeeID, [])
        }
        // Splits carry no payee of their own; the parent name drives creation.
        let name = candidate.payeeName ?? ""
        let key = name.lowercased()
        if let cachedID = resolvedPayeeIDs[key], !key.isEmpty {
            return (cachedID, [])
        }
        let resolution = try await database.resolveOrCreatePayeeMessages(
            selectedPayeeID: nil,
            payeeName: name,
            builder: &builder
        )
        if !key.isEmpty {
            resolvedPayeeIDs[key] = resolution.payeeID
        }
        return resolution
    }

    // MARK: - Screen reads (Phase 4)

    /// One row of the Settings Bank Sync list: every open budget account
    /// with its link state. Derived once here so the view model never
    /// re-derives fallback expressions over raw reads.
    struct BankSyncAccountStatusRow: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let isLinked: Bool
        let syncSource: String?
        let remoteAccountID: String?
        let lastSyncEpochMilliseconds: Int64?
        let durableStatus: String?
    }

    func bankSyncAccountRows(budgetID: String) async throws -> [BankSyncAccountStatusRow] {
        let database = try requireDatabase(for: budgetID)
        let accounts = try await database.fetchAccounts().filter { !$0.closed }
        let linked = try await database.bankSyncLinkedAccounts()
        let linkedByID = Dictionary(uniqueKeysWithValues: linked.map { ($0.id, $0) })
        return accounts.map { account in
            let link = linkedByID[account.id]
            return BankSyncAccountStatusRow(
                id: account.id,
                name: account.name,
                isLinked: link != nil,
                syncSource: link?.syncSource,
                remoteAccountID: link?.remoteAccountID,
                lastSyncEpochMilliseconds: link?.lastSync.flatMap { Int64($0) },
                durableStatus: link?.bankSyncStatus
            )
        }
    }

    // MARK: - Context

    private func bankSyncContext(budgetID: String) throws -> (
        transport: any SimpleFINServerTransport,
        token: String
    ) {
        _ = try requireDatabase(for: budgetID)
        guard let urlString = openedServerURLString,
              let url = URL(string: urlString) else {
            throw LocalFirstError.missingServerURL
        }
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        return (simpleFINTransportFactory(url), token)
    }

    /// Over-inclusive read window around the download's day range so the
    /// exact ±7-day filter lives only in the reconciler. Month-widened bounds
    /// are numerically safe on `YYYYMMDD` ints across month boundaries.
    static func monthWidenedWindow(candidateDayIDs: [String]) -> ClosedRange<Int> {
        guard let first = candidateDayIDs.min(), let last = candidateDayIDs.max(),
              let lower = Int(first.prefix(6)), let upper = Int(last.prefix(6)) else {
            return 0...99_999_999
        }
        return (lower * 100 + 1)...(upper * 100 + 31)
    }
}

/// Small helper to keep `try Unwrap(optional)` readable in apply paths.
private func Unwrap<T>(_ value: T?) throws -> T {
    guard let value else {
        throw LocalFirstError.invalidLocalWrite("missing bank sync download")
    }
    return value
}
