import Foundation
import Observation

@MainActor
@Observable
final class LocalFirstActualStore: BudgetRepositoryProtocol, AccountRepositoryProtocol, @preconcurrency TransactionRepositoryProtocol, ReportsRepositoryProtocol {
    let keychain: KeychainStore
    let fileManager: BudgetFileManager
    let syncTransportFactory: @Sendable (URL) -> any ActualSyncTransport
    let syncDebugRecorder: @MainActor (LocalFirstSyncDebugEvent) -> Void
    let pendingLocalMessageFlushRetryDelays: [Duration]
    let syncClient = SyncClient()

    var openedBudgetID: String?
    var openedGroupID: String?
    var database: BudgetDatabase?
    var openedNodeID: String?
    var openedServerURLString: String?
    var openedEncryptionContext: ActualBudgetEncryptionContext?
    var cachedBudgets: [ActualBudget] = []
    var remoteFilesByFileID: [String: ActualSyncRemoteFile] = [:]
    var accountsByBudget: [String: [AccountDisplay]] = [:]
    var monthsByBudget: [String: [String]] = [:]
    var accountTransactionsByKey: [String: TransactionFeedPage] = [:]
    var spendingTransactionsByBudget: [String: TransactionFeedPage] = [:]
    var categoryTransactionsByKey: [String: TransactionFeedPage] = [:]
    var reportsByKey: [String: ReportsDashboardSnapshot] = [:]
    var syncStatus: LocalFirstSyncStatus?
    var isFlushingPendingLocalMessages = false
    var shouldFlushPendingLocalMessagesAgain = false
    var pendingLocalMessageFlushWaiters: [CheckedContinuation<Void, Never>] = []
    var pendingLocalMessageFlushTask: Task<Void, Never>?

    init(
        keychain: KeychainStore = .actualist,
        fileManager: BudgetFileManager = BudgetFileManager(),
        syncTransportFactory: @escaping @Sendable (URL) -> any ActualSyncTransport = { ActualServerSyncClient(baseURL: $0) },
        syncDebugRecorder: @escaping @MainActor (LocalFirstSyncDebugEvent) -> Void = { _ in },
        pendingLocalMessageFlushRetryDelays: [Duration] = [.zero, .seconds(2), .seconds(8), .seconds(30)]
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
        self.syncTransportFactory = syncTransportFactory
        self.syncDebugRecorder = syncDebugRecorder
        self.pendingLocalMessageFlushRetryDelays = pendingLocalMessageFlushRetryDelays
    }

    struct TransactionFeedPage: Sendable {
        let loaded: LoadedAccountTransactions

        var nextOffset: Int {
            loaded.transactions.count
        }
    }

    let transactionPageSize = 100

    var hasOpenBudget: Bool {
        database != nil
    }

    func isOpen(budgetID: String) -> Bool {
        openedBudgetID == budgetID && database != nil
    }

    func reset() {
        pendingLocalMessageFlushTask?.cancel()
        pendingLocalMessageFlushTask = nil
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
        categoryTransactionsByKey = [:]
        reportsByKey = [:]
        syncStatus = nil
        isFlushingPendingLocalMessages = false
        shouldFlushPendingLocalMessagesAgain = false
        resumePendingLocalMessageFlushWaiters()
    }

    func eraseLocalData() throws {
        reset()
        try keychain.removeActualSyncToken()
        try keychain.removeAllLocalFirstEncryptionKeys()
        try fileManager.deleteAllImportedBudgets()
    }

    func syncStatus(budgetID: String) -> LocalFirstSyncStatus? {
        guard openedBudgetID == budgetID else {
            return nil
        }
        return syncStatus
    }

    func requireDatabase(for budgetID: String) throws -> BudgetDatabase {
        guard let database else {
            throw LocalFirstError.budgetNotOpened
        }
        guard openedBudgetID == budgetID else {
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

enum ActualServerConnectionSecurity {
    static let localHTTPWarning = "This local HTTP connection is unencrypted. Only use it on a trusted local network."
    static let remoteHTTPBlockedMessage = "HTTP is only allowed for local network Actual servers. Use HTTPS for remote servers."

    static func warningMessage(for input: String) -> String? {
        guard let components = normalizedComponents(input),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              isLocalNetworkHost(host) else {
            return nil
        }
        return localHTTPWarning
    }

    static func blockedMessage(for input: String) -> String? {
        guard let components = normalizedComponents(input),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              !isLocalNetworkHost(host) else {
            return nil
        }
        return remoteHTTPBlockedMessage
    }

    private static func normalizedComponents(_ input: String) -> URLComponents? {
        URLComponents(string: ActualServerURLNormalizer.normalize(input))
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
            return true
        }
        if normalized.hasSuffix(".local") {
            return true
        }

        let parts = normalized.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            return false
        }

        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }
}
