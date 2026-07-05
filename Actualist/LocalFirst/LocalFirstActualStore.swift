import Foundation
import Observation

@MainActor
@Observable
final class LocalFirstActualStore: BudgetRepositoryProtocol, AccountRepositoryProtocol, TransactionRepositoryProtocol {
    private let keychain: KeychainStore
    private let fileManager: BudgetFileManager
    private let syncClient = SyncClient()

    private var openedBudgetID: String?
    private var openedGroupID: String?
    private var database: BudgetDatabase?
    private var openedNodeID: String?
    private var openedServerURLString: String?
    private var openedEncryptionContext: ActualBudgetEncryptionContext?
    private var cachedBudgets: [ActualBudget] = []
    private var remoteFilesByFileID: [String: ActualSyncRemoteFile] = [:]
    private var accountsByBudget: [String: [AccountDisplay]] = [:]
    private var monthsByBudget: [String: [String]] = [:]
    private var accountTransactionsByKey: [String: LoadedAccountTransactions] = [:]
    private var spendingTransactionsByBudget: [String: LoadedAccountTransactions] = [:]
    private(set) var syncStatus: LocalFirstSyncStatus?

    init(
        keychain: KeychainStore = .actualist,
        fileManager: BudgetFileManager = BudgetFileManager()
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
    }

    var hasOpenBudget: Bool {
        database != nil
    }

    func isOpen(budgetID: String) -> Bool {
        openedBudgetID == budgetID && database != nil
    }

    func reset() {
        openedBudgetID = nil
        openedGroupID = nil
        openedNodeID = nil
        openedServerURLString = nil
        openedEncryptionContext = nil
        database = nil
        cachedBudgets = []
        remoteFilesByFileID = [:]
        accountsByBudget = [:]
        monthsByBudget = [:]
        accountTransactionsByKey = [:]
        spendingTransactionsByBudget = [:]
        syncStatus = nil
    }

    func syncStatus(budgetID: String) -> LocalFirstSyncStatus? {
        guard openedBudgetID == budgetID else {
            return nil
        }
        return syncStatus
    }

    func login(serverURLString: String, password: String) async throws {
        let serverURLString = ActualServerURLNormalizer.normalize(serverURLString)
        guard let baseURL = URL(string: serverURLString) else {
            throw ActualAPIError.invalidURL
        }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalFirstError.missingPassword
        }

        let client = ActualServerSyncClient(baseURL: baseURL)
        _ = try await client.loginMethods()
        let response = try await client.login(password: password)
        keychain.saveActualSyncToken(response.token)
    }

    func loadBudgets(serverURLString: String) async throws -> [ActualBudget] {
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }

        let client = ActualServerSyncClient(baseURL: baseURL)
        let files = try await client.listUserFiles(token: token)
        remoteFilesByFileID = files.reduce(into: [:]) { cache, file in
            cache[file.fileID] = file
        }
        cachedBudgets = files.map(\.actualBudget)
        return cachedBudgets
    }

    func openBudget(
        _ budget: ActualBudget,
        serverURLString: String,
        encryptionPassword: String? = nil
    ) async throws {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }

        // Already open for this budget: refresh in place instead of reopening the DB
        // connection and re-listing files.
        if openedBudgetID == budget.syncID, database != nil {
            openedServerURLString = serverURLString
            try await refresh(budgetID: budget.syncID, serverURLString: serverURLString)
            return
        }

        if fileManager.importedDatabaseExists(fileID: fileID),
           let metadata = try fileManager.loadMetadata(fileID: fileID) {
            do {
                try await openImportedBudget(fileID: fileID, metadata: metadata)
            } catch LocalFirstError.encryptedBudgetRequiresPassword {
                guard let encryptionPassword,
                      !encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LocalFirstError.encryptedBudgetRequiresPassword
                }
                let token = keychain.readActualSyncToken()
                guard !token.isEmpty else {
                    throw LocalFirstError.missingSyncToken
                }
                guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
                    throw ActualAPIError.invalidURL
                }
                let client = ActualServerSyncClient(baseURL: baseURL)
                let context = try await encryptionContext(
                    metadata: metadata,
                    client: client,
                    token: token,
                    password: encryptionPassword
                )
                try await openImportedBudget(fileID: fileID, metadata: metadata, encryptionContext: context)
            }
            openedServerURLString = serverURLString
            try await pullAndReload(budgetID: metadata.groupID ?? metadata.cloudFileID, serverURLString: serverURLString)
            return
        }

        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }

        let client = ActualServerSyncClient(baseURL: baseURL)
        let fallbackRemote = ActualSyncRemoteFile(
            fileID: fileID,
            groupID: budget.groupId,
            name: budget.name,
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let cachedRemote = remoteFilesByFileID[fileID]
        let fileInfo = try? await client.userFileInfo(fileID: fileID, token: token)
        let remote = fileInfo ?? cachedRemote ?? fallbackRemote
        let encryptionContext = try await encryptionContext(
            remote: remote,
            client: client,
            token: token,
            password: encryptionPassword
        )

        let data = try await client.downloadUserFile(fileID: fileID, token: token)
        let budgetData: Data
        if let encryptMeta = remote.encryptMeta {
            guard let encryptionContext else {
                throw LocalFirstError.encryptedBudgetRequiresPassword
            }
            budgetData = try ActualBudgetCrypto.decrypt(
                encryptMeta.encryptedData(data),
                keyData: encryptionContext.keyData
            )
        } else {
            budgetData = data
        }
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: budget.groupId,
            budgetName: budget.name,
            encryptionKeyID: remote.syncEncryptionKeyID,
            nodeID: HybridLogicalClock.makeClientID()
        )
        _ = try fileManager.importBudgetZip(budgetData, remoteFile: remote, metadata: metadata)
        try await openImportedBudget(fileID: fileID, metadata: metadata, encryptionContext: encryptionContext)
        openedServerURLString = serverURLString
        try await pullAndReload(budgetID: metadata.groupID ?? metadata.cloudFileID, serverURLString: serverURLString)
    }

    func openCachedBudget(_ budget: ActualBudget) async throws -> Bool {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }
        guard fileManager.importedDatabaseExists(fileID: fileID),
              let metadata = try fileManager.loadMetadata(fileID: fileID) else {
            return false
        }

        try await openImportedBudget(fileID: fileID, metadata: metadata)
        return true
    }

    /// Lean refresh for an already-open budget: pull CRDT messages and reload native caches.
    /// Does not re-list remote files or reopen the database.
    func refresh(budgetID: String, serverURLString: String) async throws {
        _ = try requireDatabase(for: budgetID)
        openedServerURLString = serverURLString
        try await pullAndReload(budgetID: budgetID, serverURLString: serverURLString)
    }

    /// Discard the locally imported SQLite database and re-download a fresh copy from the
    /// server. Used by Settings to recover from a stale or corrupted local budget; the
    /// backend stays read-only throughout.
    func reimportBudget(_ budget: ActualBudget, serverURLString: String) async throws {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }
        reset()
        try fileManager.deleteImportedBudget(fileID: fileID)
        try await openBudget(budget, serverURLString: serverURLString)
    }

    func budgets() async throws -> [ActualBudget] {
        cachedBudgets
    }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        let months = try availableMonths(budgetID: budgetID)
        let selected = months.contains(preferredMonth) ? preferredMonth : (months.last ?? preferredMonth)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: selected)
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let months = try availableMonths(budgetID: budgetID)
        let monthID = months.contains(selectedMonth) ? selectedMonth : (months.last ?? selectedMonth)
        let month = try database.fetchBudgetMonth(month: monthID)
        return LoadedBudgetMonth(
            availableMonths: months,
            selectedMonth: monthID,
            month: month,
            alerts: try nativeBudgetAlerts(database: database, month: month, monthID: monthID)
        )
    }

    func accountDisplays(budgetID: String) -> [AccountDisplay] {
        accountsByBudget[budgetID] ?? []
    }

    func refreshAccountsWithBalances(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        accountsByBudget[budgetID] = try database.fetchAccountDisplays()
    }

    // MARK: - Account mutations / server operations (read-only until CRDT writes land)

    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {
        throw LocalFirstError.unsupportedWrite
    }

    func syncBankAccountAndRefresh(budgetID: String, accountID: String) async throws -> LoadedAccountTransactions? {
        throw LocalFirstError.unsupportedWrite
    }

    func syncBankAccountAndFindNewTransactions(
        budgetID: String,
        account: ActualAccount
    ) async throws -> BackgroundAccountRefreshResult {
        throw LocalFirstError.unsupportedWrite
    }

    func syncAndFindNewTransactions(
        budget: ActualBudget,
        serverURLString: String
    ) async throws -> [BackgroundAccountRefreshResult] {
        let hasLocalBaseline = try await openBudgetForBackgroundDiffIfNeeded(
            budget,
            serverURLString: serverURLString
        )
        guard hasLocalBaseline else {
            return []
        }

        let budgetID = budget.syncID
        let database = try requireDatabase(for: budgetID)
        let transactionIDsBeforeSync = try transactionIDsByAccount(database: database)

        try await pullAndReload(budgetID: budgetID, serverURLString: serverURLString)

        let refreshedDatabase = try requireDatabase(for: budgetID)
        let transactionIDsAfterSync = try transactionIDsByAccount(database: refreshedDatabase)
        let accountDisplays: [AccountDisplay]
        if let cachedDisplays = accountsByBudget[budgetID] {
            accountDisplays = cachedDisplays
        } else {
            accountDisplays = try refreshedDatabase.fetchAccountDisplays()
        }
        let accounts = accountDisplays.map(\.account).filter { !$0.closed }

        return accounts.compactMap { account in
            let previousIDs = transactionIDsBeforeSync[account.id] ?? []
            let currentIDs = transactionIDsAfterSync[account.id] ?? []
            let newIDs = currentIDs.subtracting(previousIDs).sorted()
            guard !newIDs.isEmpty else {
                return nil
            }
            return BackgroundAccountRefreshResult(account: account, newTransactionIDs: newIDs)
        }
    }

    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> APIAccountReconciliationResult {
        throw LocalFirstError.unsupportedWrite
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try database.assignCategoryBudgetMessages(
            categoryID: categoryID,
            budgeted: budgeted,
            month: month,
            builder: &builder
        )

        try await pushLocalMessagesIfPossible(
            database: database,
            messages: messages,
            since: latestTimestamp
        )
        _ = try database.applyLocalSyncMessages(messages)
        await didAssign()
        try reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try database.budgetTemplateMessages(
            command: command,
            month: month,
            builder: &builder
        )

        try await pushLocalMessagesIfPossible(
            database: database,
            messages: messages,
            since: latestTimestamp
        )
        _ = try database.applyLocalSyncMessages(messages)
        await didApply()
        try reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(
            commands: [command],
            budgetID: budgetID,
            month: month,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try database.moveMoneyMessages(
            commands: commands,
            month: month,
            builder: &builder
        )

        try await pushLocalMessagesIfPossible(
            database: database,
            messages: messages,
            since: latestTimestamp
        )
        _ = try database.applyLocalSyncMessages(messages)
        await didMove()
        try reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    // MARK: - TransactionRepositoryProtocol (read-only)

    func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions? {
        accountTransactionsByKey[transactionKey(budgetID, accountID)]
    }

    func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions? {
        spendingTransactionsByBudget[budgetID]
    }

    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        accountTransactionsByKey[transactionKey(budgetID, accountID)] = try loadedAccountTransactions(
            database: database, budgetID: budgetID, accountID: accountID, query: nil
        )
    }

    func refreshSpendingTransactions(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        spendingTransactionsByBudget[budgetID] = try loadedSpendingTransactions(
            database: database, budgetID: budgetID, query: nil
        )
    }

    // Local SQLite loads the full live set at once, so there are no older pages to fetch.
    func loadOlderTransactions(budgetID: String, accountID: String) async throws {}
    func loadOlderSpendingTransactions(budgetID: String) async throws {}

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        return try loadedAccountTransactions(database: database, budgetID: budgetID, accountID: accountID, query: query)
    }

    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        return try loadedSpendingTransactions(database: database, budgetID: budgetID, query: query)
    }

    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        let database = try requireDatabase(for: budgetID)
        return TransactionEditorOptions(
            accounts: try database.fetchAccounts().filter { !$0.closed },
            categories: try database.fetchCategories().filter { !($0.hidden ?? false) && !($0.isIncome ?? false) },
            categoryGroups: try editorCategoryGroups(database: database, month: month),
            payees: try database.fetchPayees()
        )
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        let database = try requireDatabase(for: budgetID)
        let maps = try nameMaps(database)
        let transactions = try database.fetchTransactions().filter { transaction in
            Self.isUncategorized(
                transaction,
                month: month,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs
            )
        }
        return LoadedUncategorizedTransactions(
            transactions: transactions,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            categoryGroups: try editorCategoryGroups(database: database, month: month)
        )
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        throw LocalFirstError.unsupportedWrite
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let transactionID = UUID().uuidString
        let latestTimestamp = try database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let payeeResolution = try database.resolveOrCreatePayeeMessages(
            selectedPayeeID: draft.payeeID,
            payeeName: draft.payeeName,
            builder: &builder
        )

        let transactionMessages: [ActualSyncDecodedMessage]
        var changedAccounts = [draft.accountID]
        if draft.isTransfer {
            let transfer = try database.createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder
            )
            transactionMessages = transfer.messages
            changedAccounts.append(transfer.destinationAccountID)
        } else if draft.isSplit {
            transactionMessages = try database.createSplitTransactionMessages(
                draft: draft,
                parentTransactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder
            )
        } else {
            transactionMessages = try database.createSimpleTransactionMessages(
                draft,
                transactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder
            )
        }

        let messages = payeeResolution.messages + transactionMessages
        try await pushLocalMessagesIfPossible(
            database: database,
            messages: messages,
            since: latestTimestamp
        )
        _ = try database.applyLocalSyncMessages(messages)
        await didCreate()

        let uniqueAccounts = Array(Set(changedAccounts))
        try reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: uniqueAccounts,
            monthIDs: [draft.month.rawValue]
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: uniqueAccounts,
                months: [draft.month.rawValue],
                transactions: [transactionID]
            )
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }

        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let payeeResolution = try database.resolveOrCreatePayeeMessages(
            selectedPayeeID: draft.payeeID,
            payeeName: draft.payeeName,
            builder: &builder
        )
        let update = try database.updateTransactionMessages(
            transactionID: transactionID,
            draft: draft,
            payeeID: payeeResolution.payeeID,
            builder: &builder
        )

        let messages = payeeResolution.messages + update.messages
        try await pushLocalMessagesIfPossible(
            database: database,
            messages: messages,
            since: latestTimestamp
        )
        _ = try database.applyLocalSyncMessages(messages)
        await didUpdate()

        let changedAccounts = Array(Set(update.affectedAccountIDs + [originalAccountID, draft.accountID]))
        let changedMonths = Array(Set([originalMonth, draft.month.rawValue]))
        try reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: changedAccounts,
            monthIDs: changedMonths
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: changedMonths,
                transactions: update.affectedTransactionIDs
            )
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let transactionID = transaction.id, !transactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard let monthID = transaction.date.actualYearMonth else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }

        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try database.categorizeTransactionMessages(
            transactionID: transactionID,
            categoryID: categoryID,
            builder: &builder
        )

        try await pushLocalMessagesIfPossible(
            database: database,
            messages: messages,
            since: latestTimestamp
        )
        _ = try database.applyLocalSyncMessages(messages)
        await didUpdate()
        try reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: [transaction.account],
            monthIDs: [monthID]
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: [monthID],
                transactions: [transactionID]
            )
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let transactionID = transaction.id, !transactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard let monthID = transaction.date.actualYearMonth else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }

        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let delete = try database.deleteTransactionMessages(
            transactionID: transactionID,
            builder: &builder
        )

        try await pushLocalMessagesIfPossible(
            database: database,
            messages: delete.messages,
            since: latestTimestamp
        )
        _ = try database.applyLocalSyncMessages(delete.messages)
        await didDelete()

        let changedAccounts = Array(Set(delete.affectedAccountIDs + [transaction.account]))
        try reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: changedAccounts,
            monthIDs: [monthID]
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: [monthID],
                transactions: delete.affectedTransactionIDs
            )
        )
    }

    private func loadedAccountTransactions(
        database: BudgetDatabase,
        budgetID: String,
        accountID: String,
        query: String?
    ) throws -> LoadedAccountTransactions {
        let maps = try nameMaps(database)
        let balance = accountsByBudget[budgetID]?.first(where: { $0.account.id == accountID })?.balance
        return LoadedAccountTransactions(
            transactions: try database.fetchTransactions(accountID: accountID, matching: query),
            balance: balance,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            reachedEnd: true
        )
    }

    private func loadedSpendingTransactions(
        database: BudgetDatabase,
        budgetID: String,
        query: String?
    ) throws -> LoadedAccountTransactions {
        let maps = try nameMaps(database)
        return LoadedAccountTransactions(
            transactions: try database.fetchTransactions(matching: query),
            balance: nil,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            reachedEnd: true
        )
    }

    /// Derives budget banner alerts natively from SQLite, matching the REST server's shapes so
    /// the UI renders identically across backends. Every alert here is view-only: the sheets
    /// they open (uncategorized review, overspent categories) present read-only, and the
    /// to-budget banner is informational. Their embedded write actions stay disabled by the
    /// backend capability gate, exactly as in offline REST.
    private func nativeBudgetAlerts(
        database: BudgetDatabase,
        month: BudgetMonth,
        monthID: String
    ) throws -> [APIBudgetMonthAlert] {
        let maps = try nameMaps(database)
        let transactions = try database.fetchTransactions()
        return Self.budgetAlerts(
            month: month,
            monthID: monthID,
            transactions: transactions,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs
        )
    }

    /// Pure derivation of the full budget alert list (to-budget, overspending, uncategorized),
    /// ordered to match the REST server. Exposed for testing.
    static func budgetAlerts(
        month: BudgetMonth,
        monthID: String,
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> [APIBudgetMonthAlert] {
        var alerts: [APIBudgetMonthAlert] = []
        if let toBudget = toBudgetAlert(month: month) {
            alerts.append(toBudget)
        }
        if let overspending = overspendingAlert(month: month) {
            alerts.append(overspending)
        }
        alerts.append(contentsOf: uncategorizedAlerts(
            transactions: transactions,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: offBudgetAccountIDs,
            month: monthID
        ))
        return alerts
    }

    /// "To Budget" banner showing the amount left to assign this month. Informational only
    /// (non-actionable). A surplus reads positive; a negative value means the month is
    /// overbudgeted (Actual allows this) and reads as a warning, carrying the signed amount.
    static func toBudgetAlert(month: BudgetMonth) -> APIBudgetMonthAlert? {
        guard month.toBudget != 0 else {
            return nil
        }
        return APIBudgetMonthAlert(
            kind: "toBudget",
            severity: month.toBudget > 0 ? "positive" : "warning",
            title: "To Budget",
            amount: month.toBudget,
            count: nil,
            actionTitle: nil
        )
    }

    /// Overspending banner counting categories that ended the month negative. The count mirrors
    /// the overspent-categories review sheet, which opens read-only in local-first mode.
    static func overspendingAlert(month: BudgetMonth) -> APIBudgetMonthAlert? {
        let overspentCount = month.categoryGroups
            .filter { !$0.isIncome }
            .flatMap(\.categories)
            .filter { !($0.hidden ?? false) && $0.balance < 0 }
            .count
        guard overspentCount > 0 else {
            return nil
        }
        return APIBudgetMonthAlert(
            kind: "overspending",
            severity: "danger",
            title: "Overspent categories",
            amount: nil,
            count: overspentCount,
            actionTitle: "Cover"
        )
    }

    /// Pure derivation of the uncategorized-transactions alert, matching the REST server's
    /// wording/severity so the UI renders identically across backends. Exposed for testing.
    static func uncategorizedAlerts(
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>,
        month: String
    ) -> [APIBudgetMonthAlert] {
        let count = transactions.filter {
            isUncategorized(
                $0,
                month: month,
                transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
                offBudgetAccountIDs: offBudgetAccountIDs
            )
        }.count
        guard count > 0 else {
            return []
        }
        return [
            APIBudgetMonthAlert(
                kind: "uncategorizedTransactions",
                severity: "warning",
                title: "Uncategorized transactions",
                amount: nil,
                count: count,
                actionTitle: "Review"
            )
        ]
    }

    /// A top-level transaction needs categorizing when it falls in the month, carries no
    /// category, is not a split parent, and is not an on-budget-to-on-budget transfer. Transfers
    /// between an on-budget account and an off-budget account still need categories in Actual.
    static func isUncategorized(
        _ transaction: ActualTransaction,
        month: String,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> Bool {
        let destinationAccountID = transaction.payee.flatMap { transferAccountIDsByPayeeID[$0] }
        let isOnBudgetTransfer = destinationAccountID.map { !offBudgetAccountIDs.contains($0) } ?? false
        return transaction.date.hasPrefix(month)
            && (transaction.category?.isEmpty ?? true)
            && transaction.subtransactions.isEmpty
            && !transaction.isParent
            && !isOnBudgetTransfer
    }

    private func editorCategoryGroups(database: BudgetDatabase, month: String) throws -> [TransactionEditorCategoryGroup] {
        let budgetMonth = try database.fetchBudgetMonth(month: month)
        return budgetMonth.categoryGroups.compactMap { group in
            guard !group.isIncome else {
                return nil
            }
            let options = group.categories
                .filter { !($0.hidden ?? false) && !$0.isIncome }
                .map { category in
                    TransactionEditorCategoryOption(
                        id: category.id,
                        title: category.name.actualistCategoryNameParts.name,
                        amount: category.balance,
                        valueText: category.balance.actualMoney.formatted()
                    )
                }
            guard !options.isEmpty else {
                return nil
            }
            return TransactionEditorCategoryGroup(id: group.id, name: group.name, options: options)
        }
    }

    private func nameMaps(
        _ database: BudgetDatabase
    ) throws -> (
        accountNames: [String: String],
        categoryNames: [String: String],
        payeeNames: [String: String],
        transferPayeeIDs: Set<String>,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) {
        let accounts = try database.fetchAccounts()
        let categories = try database.fetchCategories()
        let payees = try database.fetchPayees()
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.compactMap { category in
            category.id.map { ($0, category.name) }
        })
        // Transfer payees carry an empty name; display them as the linked account's name.
        let payeeNames = Dictionary(uniqueKeysWithValues: payees.compactMap { payee -> (String, String)? in
            guard let id = payee.id else {
                return nil
            }
            if payee.name.isEmpty, let transferAccount = payee.transferAccount, let accountName = accountNames[transferAccount] {
                return (id, accountName)
            }
            return (id, payee.name)
        })
        let transferPayeeIDs = Set(payees.compactMap { payee -> String? in
            payee.transferAccount != nil ? payee.id : nil
        })
        let transferAccountIDsByPayeeID = Dictionary(uniqueKeysWithValues: payees.compactMap { payee -> (String, String)? in
            guard let id = payee.id, let transferAccount = payee.transferAccount else {
                return nil
            }
            return (id, transferAccount)
        })
        let offBudgetAccountIDs = Set(accounts.filter(\.offbudget).map(\.id))
        return (accountNames, categoryNames, payeeNames, transferPayeeIDs, transferAccountIDsByPayeeID, offBudgetAccountIDs)
    }

    private func transactionKey(_ budgetID: String, _ accountID: String) -> String {
        "\(budgetID)|\(accountID)"
    }

    private func openBudgetForBackgroundDiffIfNeeded(
        _ budget: ActualBudget,
        serverURLString: String
    ) async throws -> Bool {
        if isOpen(budgetID: budget.syncID) {
            return true
        }
        if openedBudgetID != nil {
            reset()
        }
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }
        if fileManager.importedDatabaseExists(fileID: fileID),
           let metadata = try fileManager.loadMetadata(fileID: fileID) {
            try await openImportedBudget(fileID: fileID, metadata: metadata)
            return true
        }

        try await openBudget(budget, serverURLString: serverURLString)
        return false
    }

    private func openImportedBudget(
        fileID: String,
        metadata: LocalFirstBudgetMetadata,
        encryptionContext providedEncryptionContext: ActualBudgetEncryptionContext? = nil
    ) async throws {
        let encryptionContext = try providedEncryptionContext ?? encryptionContext(metadata: metadata)
        let database = try BudgetDatabase(databaseURL: fileManager.databaseURL(fileID: fileID))
        self.database = database
        openedBudgetID = metadata.groupID ?? metadata.cloudFileID
        openedGroupID = metadata.groupID
        openedNodeID = metadata.nodeID
        openedEncryptionContext = encryptionContext
        try? accountsByBudget[metadata.groupID ?? metadata.cloudFileID] = database.fetchAccountDisplays()
        await syncClient.configure(
            LocalFirstSyncConfiguration(
                fileID: metadata.cloudFileID,
                groupID: metadata.groupID,
                nodeID: metadata.nodeID,
                encryptionKeyID: encryptionContext?.keyID,
                encryptionContext: encryptionContext
            )
        )
    }

    private func encryptionContext(metadata: LocalFirstBudgetMetadata) throws -> ActualBudgetEncryptionContext? {
        guard let keyID = metadata.encryptionKeyID else {
            return nil
        }
        guard let keyData = keychain.readLocalFirstEncryptionKey(
            fileID: metadata.cloudFileID,
            keyID: keyID
        ) else {
            throw LocalFirstError.encryptedBudgetRequiresPassword
        }
        return ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)
    }

    private func encryptionContext(
        metadata: LocalFirstBudgetMetadata,
        client: ActualServerSyncClient,
        token: String,
        password: String
    ) async throws -> ActualBudgetEncryptionContext {
        guard let keyID = metadata.encryptionKeyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        let keyResponse = try await client.userKey(fileID: metadata.cloudFileID, token: token)
        let context = try ActualBudgetCrypto.validateUserKeyResponse(
            keyResponse,
            password: password
        )
        guard context.keyID == keyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        keychain.saveLocalFirstEncryptionKey(
            context.keyData,
            fileID: metadata.cloudFileID,
            keyID: keyID
        )
        return context
    }

    private func encryptionContext(
        remote: ActualSyncRemoteFile,
        client: ActualServerSyncClient,
        token: String,
        password: String?
    ) async throws -> ActualBudgetEncryptionContext? {
        guard remote.requiresEncryptionPassword else {
            return nil
        }
        guard let keyID = remote.syncEncryptionKeyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        if let keyData = keychain.readLocalFirstEncryptionKey(fileID: remote.fileID, keyID: keyID) {
            return ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)
        }
        guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalFirstError.encryptedBudgetRequiresPassword
        }

        let keyResponse = try await client.userKey(fileID: remote.fileID, token: token)
        let context = try ActualBudgetCrypto.validateUserKeyResponse(
            keyResponse,
            password: password
        )
        guard context.keyID == keyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        keychain.saveLocalFirstEncryptionKey(context.keyData, fileID: remote.fileID, keyID: keyID)
        return context
    }

    private func transactionIDsByAccount(database: BudgetDatabase) throws -> [String: Set<String>] {
        try database.fetchTransactions().reduce(into: [:]) { idsByAccount, transaction in
            insertTransactionID(transaction, into: &idsByAccount)
            for child in transaction.subtransactions {
                insertTransactionID(child, into: &idsByAccount)
            }
        }
    }

    private func insertTransactionID(
        _ transaction: ActualTransaction,
        into idsByAccount: inout [String: Set<String>]
    ) {
        guard let id = transaction.id, !id.isEmpty, !transaction.account.isEmpty else {
            return
        }
        idsByAccount[transaction.account, default: []].insert(id)
    }

    private func reloadAfterTransactionMutation(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: [String],
        monthIDs: [String]
    ) throws {
        monthsByBudget[budgetID] = nil
        accountsByBudget[budgetID] = try database.fetchAccountDisplays()
        spendingTransactionsByBudget[budgetID] = try loadedSpendingTransactions(
            database: database,
            budgetID: budgetID,
            query: nil
        )
        for accountID in Set(accountIDs) {
            accountTransactionsByKey[transactionKey(budgetID, accountID)] = try loadedAccountTransactions(
                database: database,
                budgetID: budgetID,
                accountID: accountID,
                query: nil
            )
        }
        for monthID in Set(monthIDs) {
            _ = try database.fetchBudgetMonth(month: monthID)
        }
    }

    private func reloadAfterBudgetMutation(
        database: BudgetDatabase,
        budgetID: String
    ) throws {
        monthsByBudget[budgetID] = nil
        accountsByBudget[budgetID] = try database.fetchAccountDisplays()
        spendingTransactionsByBudget[budgetID] = try loadedSpendingTransactions(
            database: database,
            budgetID: budgetID,
            query: nil
        )
    }

    private func pushLocalMessagesIfPossible(
        database: BudgetDatabase,
        messages: [ActualSyncDecodedMessage],
        since: String
    ) async throws {
        guard !messages.isEmpty,
              let serverURLString = openedServerURLString,
              !serverURLString.isEmpty else {
            return
        }
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            return
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }
        let client = ActualServerSyncClient(baseURL: baseURL)
        _ = try await syncClient.pushAndPull(
            database: database,
            client: client,
            token: token,
            messages: messages,
            since: since
        )
    }

    /// Pull remote CRDT messages, apply them, then unconditionally invalidate and reload
    /// native read caches so they are authoritative after any refresh. Records sync status.
    private func pullAndReload(budgetID: String, serverURLString: String) async throws {
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }
        let database = try requireDatabase(for: budgetID)

        let client = ActualServerSyncClient(baseURL: baseURL)
        do {
            let appliedCount = try await syncClient.pullAndApply(
                database: database,
                client: client,
                token: token
            )
            #if DEBUG
            print("[Actualist LocalFirst] Applied \(appliedCount) remote sync messages for \(budgetID)")
            #endif

            monthsByBudget[budgetID] = nil
            accountsByBudget[budgetID] = try database.fetchAccountDisplays()
            accountTransactionsByKey = accountTransactionsByKey.filter { !$0.key.hasPrefix("\(budgetID)|") }
            spendingTransactionsByBudget[budgetID] = nil
            recordSyncStatus(budgetID: budgetID, appliedCount: appliedCount, error: nil)
        } catch {
            recordSyncStatus(budgetID: budgetID, appliedCount: nil, error: error)
            throw error
        }
    }

    private func recordSyncStatus(budgetID: String, appliedCount: Int?, error: Error?) {
        var status = syncStatus ?? LocalFirstSyncStatus(fileID: budgetID, groupID: openedGroupID)
        status.fileID = budgetID
        status.groupID = openedGroupID
        status.encryptionKeyID = openedEncryptionContext?.keyID
        if let appliedCount {
            status.lastSyncedAt = Date()
            status.lastAppliedMessageCount = appliedCount
            status.lastError = nil
        } else {
            status.lastError = error?.localizedDescription
        }
        syncStatus = status
    }

    private func availableMonths(budgetID: String) throws -> [String] {
        if let months = monthsByBudget[budgetID] {
            return months
        }
        let months = try requireDatabase(for: budgetID).fetchAvailableMonths()
        monthsByBudget[budgetID] = months
        return months
    }

    private func requireDatabase(for budgetID: String) throws -> BudgetDatabase {
        guard openedBudgetID == nil || openedBudgetID == budgetID || database != nil else {
            throw LocalFirstError.budgetNotOpened
        }
        guard let database else {
            throw LocalFirstError.budgetNotOpened
        }
        return database
    }
}

enum ActualServerURLNormalizer {
    static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else {
            return withScheme
        }
        if components.path == "/" {
            components.path = ""
        }
        return components.string ?? withScheme
    }
}
