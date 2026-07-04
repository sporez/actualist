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

    func openBudget(_ budget: ActualBudget, serverURLString: String) async throws {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }

        // Already open for this budget: refresh in place instead of reopening the DB
        // connection and re-listing files.
        if openedBudgetID == budget.syncID, database != nil {
            try await refresh(budgetID: budget.syncID, serverURLString: serverURLString)
            return
        }

        if fileManager.importedDatabaseExists(fileID: fileID),
           let metadata = try fileManager.loadMetadata(fileID: fileID) {
            try await openImportedBudget(fileID: fileID, metadata: metadata)
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
        if remote.requiresEncryptionPassword {
            throw LocalFirstError.encryptedBudgetRequiresPassword
        }

        let data = try await client.downloadUserFile(fileID: fileID, token: token)
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: budget.groupId,
            budgetName: budget.name,
            encryptionKeyID: remote.encryptKeyID,
            nodeID: UUID().uuidString
        )
        _ = try fileManager.importBudgetZip(data, remoteFile: remote, metadata: metadata)
        try await openImportedBudget(fileID: fileID, metadata: metadata)
        try await pullAndReload(budgetID: metadata.groupID ?? metadata.cloudFileID, serverURLString: serverURLString)
    }

    /// Lean refresh for an already-open budget: pull CRDT messages and reload native caches.
    /// Does not re-list remote files or reopen the database.
    func refresh(budgetID: String, serverURLString: String) async throws {
        _ = try requireDatabase(for: budgetID)
        try await pullAndReload(budgetID: budgetID, serverURLString: serverURLString)
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
        return LoadedBudgetMonth(
            availableMonths: months,
            selectedMonth: monthID,
            month: try database.fetchBudgetMonth(month: monthID),
            alerts: []
        )
    }

    func accountDisplays(budgetID: String) -> [AccountDisplay] {
        accountsByBudget[budgetID] ?? []
    }

    func refreshAccountsWithBalances(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        accountsByBudget[budgetID] = try database.fetchAccountDisplays()
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
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
            transaction.date.hasPrefix(month)
                && (transaction.category?.isEmpty ?? true)
                && transaction.subtransactions.isEmpty
                && !transaction.isParent
                && !(transaction.payee.map { maps.transferPayeeIDs.contains($0) } ?? false)
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
        throw LocalFirstError.unsupportedWrite
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        throw LocalFirstError.unsupportedWrite
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        throw LocalFirstError.unsupportedWrite
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        throw LocalFirstError.unsupportedWrite
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
    ) throws -> (accountNames: [String: String], categoryNames: [String: String], payeeNames: [String: String], transferPayeeIDs: Set<String>) {
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
        return (accountNames, categoryNames, payeeNames, transferPayeeIDs)
    }

    private func transactionKey(_ budgetID: String, _ accountID: String) -> String {
        "\(budgetID)|\(accountID)"
    }

    private func openImportedBudget(fileID: String, metadata: LocalFirstBudgetMetadata) async throws {
        let database = try BudgetDatabase(databaseURL: fileManager.databaseURL(fileID: fileID))
        self.database = database
        openedBudgetID = metadata.groupID ?? metadata.cloudFileID
        openedGroupID = metadata.groupID
        try? accountsByBudget[metadata.groupID ?? metadata.cloudFileID] = database.fetchAccountDisplays()
        await syncClient.configure(
            LocalFirstSyncConfiguration(
                fileID: metadata.cloudFileID,
                groupID: metadata.groupID,
                nodeID: metadata.nodeID,
                encryptionKeyID: metadata.encryptionKeyID
            )
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
