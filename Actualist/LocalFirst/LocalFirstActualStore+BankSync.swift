import Foundation

/// SimpleFIN bank-sync orchestration (plan Phase 3): download → normalize →
/// rule projection → reconciler plan → review DTO → confirm → CRDT writes.
/// The UI (Phase 4) only renders `BankSyncReview.AccountPlan` and calls the
/// intents here; all payload math, state, and write orchestration live in
/// this file and `BudgetDatabase+BankSync.swift`.
extension LocalFirstActualStore {
    enum BankSyncStoreError: LocalizedError, Equatable {
        case staleGeneration
        case unresolvedProblems
        case notLinked
        case notSimpleFINLinked
        case serverCannotBankSync

        var errorDescription: String? {
            switch self {
            case .staleGeneration:
                return "This bank sync review is stale. Download again."
            case .unresolvedProblems:
                return "Bank sync found transactions it could not safely read. Nothing was saved."
            case .notLinked:
                return "This account is not linked to a bank."
            case .notSimpleFINLinked:
                return "Only SimpleFIN-linked accounts can sync here."
            case .serverCannotBankSync:
                return "Your server does not provide SimpleFIN, so background bank sync cannot run."
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
    /// the device key when one exists and rethrows otherwise. The
    /// background path passes `deviceFallback: false` — the Phase 5 device
    /// key is never used there.
    func bankSyncProvider(
        budgetID: String,
        deviceFallback: Bool = true
    ) async throws -> BankSyncProvider {
        _ = try requireDatabase(for: budgetID)
        do {
            let context = try bankSyncContext(budgetID: budgetID)
            let support = try await context.transport.simpleFINStatus(token: context.token)
            if support == .configured {
                return .server(transport: context.transport, token: context.token)
            }
            if !deviceFallback {
                throw BankSyncStoreError.serverCannotBankSync
            }
            if let device = try? bankSyncDeviceClient() {
                return .device(device)
            }
            return .server(transport: context.transport, token: context.token)
        } catch let error as ActualAPIError {
            if deviceFallback, case .transport = error, let device = try? bankSyncDeviceClient() {
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

    /// loot-core `unlinkAccount`: clear a SimpleFIN link's columns and leave
    /// transactions. Other provider metadata is outside this mutation path.
    func unlinkBankAccount(_ localAccountID: String, budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        guard let linked = try await database.bankSyncLinkedAccounts()
            .first(where: { $0.id == localAccountID }) else {
            throw BankSyncStoreError.notLinked
        }
        guard BankSyncLinkEligibility.isSimpleFIN(syncSource: linked.syncSource) else {
            throw BankSyncStoreError.notSimpleFINLinked
        }
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
        guard plan.problems.isEmpty else {
            throw BankSyncStoreError.unresolvedProblems
        }
        try Task.checkCancellation()

        var builder = LocalFirstSyncMessageBuilder()
        var messages: [ActualSyncDecodedMessage] = []
        var resolvedPayeeIDs: [String: String] = [:]
        var categorizedIDs = Set<String>()
        var insertedCount = 0
        var updatedCount = 0
        var collectedInsertedIDs: [String] = []
        let sortOrderBase = Date().timeIntervalSince1970 * 1_000

        if let openingBalance = plan.openingBalance {
            let onBudget = !(try await database.bankSyncLinkedAccounts()
                .first { $0.id == plan.accountID }?.offbudget ?? false)
            let openingBalanceID = UUID().uuidString
            collectedInsertedIDs.append(openingBalanceID)
            messages.append(contentsOf: try await database.makeBankSyncOpeningBalanceMessages(
                transactionID: openingBalanceID,
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
            try Task.checkCancellation()
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
            try Task.checkCancellation()
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
            collectedInsertedIDs.append(transactionID)
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

        try Task.checkCancellation()
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
            openingBalanceInserted: plan.openingBalance != nil,
            insertedTransactionIDs: collectedInsertedIDs
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

    /// Background bank-sync step (plan Phase 6): download + auto-apply for
    /// every open SimpleFIN-linked account through the SERVER connection
    /// only. Runs after a successful background `/sync/sync`; the toggle is
    /// consent to apply without a review sheet. Returns the inserted
    /// transaction IDs per local account so the workflow can feed the
    /// existing new-transaction notification pipeline (when the alerts
    /// toggle is also on).
    func backgroundBankSyncApply(
        budgetID: String
    ) async throws -> BankSyncBackgroundApplyResult {
        let database = try requireDatabase(for: budgetID)
        // Server SimpleFIN only; the Phase 5 device key is never read here.
        // The batched planner's provider resolution enforces configured server
        // support once for the entire run.
        let openAccountIDs = try await database.fetchAccounts()
            .filter { !$0.closed }
            .map(\.id)
        let linked = try await database.bankSyncLinkedAccounts()
            .filter {
                BankSyncLinkEligibility.isSimpleFIN(syncSource: $0.syncSource)
                    && openAccountIDs.contains($0.id)
            }
        if linked.isEmpty {
            guard try await bankSyncSupport(budgetID: budgetID) == .configured else {
                throw BankSyncStoreError.serverCannotBankSync
            }
            return BankSyncBackgroundApplyResult(
                accountCount: 0,
                insertedTransactionIDsByAccount: [:]
            )
        }

        let plans = try await downloadBankSyncPlans(
            accountIDs: linked.map(\.id),
            budgetID: budgetID,
            deviceFallback: false
        )
        // Preflight every account before the first write. A malformed row in a
        // later account cannot leave earlier accounts applied from this wake.
        guard plans.allSatisfy(\.problems.isEmpty) else {
            throw BankSyncStoreError.unresolvedProblems
        }

        var insertedTransactionIDsByAccount: [String: [String]] = [:]
        for plan in plans {
            try Task.checkCancellation()
            let result = try await applyBankSyncPlan(plan, budgetID: budgetID)
            if !result.insertedTransactionIDs.isEmpty {
                insertedTransactionIDsByAccount[plan.accountID] = result.insertedTransactionIDs
            }
        }
        return BankSyncBackgroundApplyResult(
            accountCount: linked.count,
            insertedTransactionIDsByAccount: insertedTransactionIDsByAccount
        )
    }

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

}

/// Small helper to keep `try Unwrap(optional)` readable in apply paths.
private func Unwrap<T>(_ value: T?) throws -> T {
    guard let value else {
        throw LocalFirstError.invalidLocalWrite("missing bank sync download")
    }
    return value
}

/// The store is the production conformer of the background workflow's
/// bank-sync step seam.
extension LocalFirstActualStore: BackgroundBankSyncApplying {}
