import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class LocalFirstActualStore: BudgetRepositoryProtocol, AccountRepositoryProtocol, EntityNotesRepositoryProtocol, PayeeRepositoryProtocol, RuleRepositoryProtocol, TransactionRepositoryProtocol, ReportsRepositoryProtocol {
    let keychain: KeychainStore
    let fileManager: BudgetFileManager
    let syncTransportFactory: (@Sendable (URL) -> any ActualSyncTransport)?
    let connectionTransportFactory: (@Sendable (URL) -> any ActualServerConnectionTransport)?
    /// SimpleFIN bank-sync transport seam; a stub in tests.
    let simpleFINTransportFactory: (@Sendable (URL) -> any SimpleFINServerTransport)?
    let openIDAuthenticationCoordinator = ActualOpenIDAuthenticationCoordinator()
    let syncDebugRecorder: @MainActor (LocalFirstSyncDebugEvent) -> Void
    let pendingLocalMessageFlushRetryDelays: [Duration]
    let syncClient = SyncClient()

    var openedBudgetID: String?
    var openedGroupID: String?
    var database: BudgetDatabase?
    var launchSnapshotFiles: BudgetLaunchSnapshotFiles?
    var launchSnapshotContext: BudgetLaunchSnapshotContext?
    var launchSnapshotWrittenRevision: UInt64?
    var openedNodeID: String?
    var openedServerURLString: String? {
        didSet { refreshEndpointHealthDisplay() }
    }
    var openedEncryptionContext: ActualBudgetEncryptionContext?
    var cachedBudgets: [ActualBudget] = []
    var remoteFilesByFileID: [String: ActualSyncRemoteFile] = [:]
    var accountsByBudget: [String: [AccountDisplay]] = [:]
    var accountGroupsByBudget: [String: [ActualAccountGroup]] = [:]
    var accountGroupManagementEnabledByBudget: [String: Bool] = [:]
    var payeesByBudget: [String: PayeeManagementSnapshot] = [:]
    var lastPayeeUndoMessagesByBudget: [String: [ActualSyncDecodedMessage]] = [:]
    var actionLogDiagnosticSnapshot = ActionLogDiagnosticSnapshot.empty
    var rulesByBudget: [String: [ManagedRule]] = [:]
    var budgetReadGeneration = 0
    var monthsByBudget: [String: [String]] = [:]
    var loadedBudgetMonthsByBudget: [String: LoadedBudgetMonth] = [:]
    var templateBrowserByBudget: [String: BudgetTemplateBrowserSnapshot] = [:]
    var accountTransactionsByKey: [String: TransactionFeedPage] = [:]
    var spendingTransactionsByBudget: [String: TransactionFeedPage] = [:]
    var categoryTransactionsByKey: [String: TransactionFeedPage] = [:]
    var uncategorizedTransactionsByKey: [String: LoadedUncategorizedTransactions] = [:]
    var reportsByKey: [String: ReportsDashboardSnapshot] = [:]
    var currencyByBudget: [String: BudgetCurrency] = [:]
    /// Bank-sync download token per local account. Replaced before every
    /// download; apply refuses a plan whose generation is no longer current,
    /// so a stale review can never write.
    var bankSyncGenerationByAccount: [String: UUID] = [:]
    /// Optional fallback server URL used when the primary server is unreachable.
    /// Set by `AppState` from `AppSettings.fallbackServerURLString`. When non-nil
    /// and distinct from the primary URL, sync and connection operations retry
    /// against this endpoint on host-unreachable failures.
    var fallbackServerURLString: String? {
        didSet { refreshEndpointHealthDisplay() }
    }

    var syncStatus: LocalFirstSyncStatus?
    /// `true` while the open budget is the bundled demo budget. Set inside
    /// `openImportedBudget` when `metadata.cloudFileID == DemoBudget.fileID`
    /// and cleared in `closeOpenBudget()`, so the store layer is demo-aware
    /// even on the generic cached-restore path. Sync/flush guards key off
    /// this so demo mode never touches a transport.
    var isDemoBudgetActive = false
    /// Endpoint used by the most recent sync/connection attempt. Set by the
    /// failover wrappers before each transport attempt so success and failure
    /// paths can attribute the result. Read by sync-status and debug-event
    /// recording; not persisted.
    var lastSyncEndpoint: LocalFirstSyncDebugEvent.Endpoint = .primary
    var isFlushingPendingLocalMessages = false
    var shouldFlushPendingLocalMessagesAgain = false
    var pendingLocalMessageFlushWaiters: [CheckedContinuation<Void, Never>] = []
    var pendingLocalMessageFlushTask: Task<Void, Never>?

    /// Cached transports per base URL so `ActualServerSyncClient.hasConnected`
    /// (and the underlying URLSession connection pool) persists across syncs.
    /// This is what makes an established server fail fast when it later becomes
    /// unreachable: the one-time Local Network permission retry loop only runs
    /// before the first successful connection, so failover to the fallback is
    /// not delayed by ~10s on every sync. Cleared by `reset()`.
    private var cachedSyncTransportsByURL: [String: any ActualSyncTransport] = [:]
    private var cachedConnectionTransportsByURL: [String: any ActualServerConnectionTransport] = [:]
    private var cachedSimpleFINTransportsByURL: [String: any SimpleFINServerTransport] = [:]
    /// Last-known SimpleFIN status and remote accounts for the Bank Sync screen.
    /// Mutations are ignored so the optimistic UI copies values onto the view
    /// model instead of observing this cache directly.
    @ObservationIgnored var bankSyncSessionCache = BankSyncSessionCache()

    /// Raw TTL cache. Ignored so mutations do not publish; the Developer sheet
    /// observes `endpointHealthDisplay` instead.
    @ObservationIgnored private var endpointHealth: ServerEndpointHealth
    /// Prepared Developer-sheet snapshot of the primary-unreachable cache.
    private(set) var endpointHealthDisplay = ServerEndpointHealthDisplay.empty

    // Session injection exercises the production endpoint/header construction in tests.
    let transportSession: URLSession?
    private(set) var customHeadersRevision = 0

    func saveCustomHTTPHeaders(_ configuration: CustomHTTPHeaderConfiguration) throws {
        try keychain.saveCustomHTTPHeaders(configuration)
        invalidateNetworkTransports()
        bankSyncSessionCache.clear()
        customHeadersRevision &+= 1
    }

    func invalidateNetworkTransports() {
        cachedSyncTransportsByURL = [:]
        cachedConnectionTransportsByURL = [:]
        cachedSimpleFINTransportsByURL = [:]
    }

    func syncTransport(for url: URL, role: ActualServerEndpointRole = .primary) throws -> any ActualSyncTransport {
        let fields = try keychain.readCustomHTTPHeaders().fields(for: role, url: url)
        let key = role.rawValue + ":" + url.absoluteString
        if let cached = cachedSyncTransportsByURL[key] { return cached }
        let transport = syncTransportFactory?(url)
            ?? ActualServerSyncClient(baseURL: url, customHeaders: fields, session: transportSession)
        cachedSyncTransportsByURL[key] = transport
        return transport
    }

    func connectionTransport(for url: URL, role: ActualServerEndpointRole = .primary) throws -> any ActualServerConnectionTransport {
        let fields = try keychain.readCustomHTTPHeaders().fields(for: role, url: url)
        let key = role.rawValue + ":" + url.absoluteString
        if let cached = cachedConnectionTransportsByURL[key] { return cached }
        let transport = connectionTransportFactory?(url)
            ?? ActualServerSyncClient(baseURL: url, customHeaders: fields, session: transportSession)
        cachedConnectionTransportsByURL[key] = transport
        return transport
    }

    func simpleFINTransport(for url: URL, role: ActualServerEndpointRole = .primary) throws -> any SimpleFINServerTransport {
        let fields = try keychain.readCustomHTTPHeaders().fields(for: role, url: url)
        let key = role.rawValue + ":" + url.absoluteString
        if let cached = cachedSimpleFINTransportsByURL[key] { return cached }
        let transport = simpleFINTransportFactory?(url)
            ?? ActualServerSimpleFINClient(baseURL: url, customHeaders: fields, session: transportSession)
        cachedSimpleFINTransportsByURL[key] = transport
        return transport
    }

    init(
        keychain: KeychainStore = .actualist,
        fileManager: BudgetFileManager = BudgetFileManager(),
        syncTransportFactory: (@Sendable (URL) -> any ActualSyncTransport)? = nil,
        connectionTransportFactory: (@Sendable (URL) -> any ActualServerConnectionTransport)? = nil,
        simpleFINTransportFactory: (@Sendable (URL) -> any SimpleFINServerTransport)? = nil,
        transportSession: URLSession? = nil,
        syncDebugRecorder: @escaping @MainActor (LocalFirstSyncDebugEvent) -> Void = { _ in },
        pendingLocalMessageFlushRetryDelays: [Duration] = [.zero, .seconds(2), .seconds(8), .seconds(30)],
        endpointHealth: ServerEndpointHealth? = nil
    ) {
        self.keychain = keychain
        self.transportSession = transportSession
        self.fileManager = fileManager
        self.syncTransportFactory = syncTransportFactory
        self.connectionTransportFactory = connectionTransportFactory
        self.simpleFINTransportFactory = simpleFINTransportFactory
        self.syncDebugRecorder = syncDebugRecorder
        self.pendingLocalMessageFlushRetryDelays = pendingLocalMessageFlushRetryDelays
        // Constructed in the main-actor init body (not a default argument) so
        // the @MainActor struct is built in an isolated context.
        self.endpointHealth = endpointHealth ?? ServerEndpointHealth()
        refreshEndpointHealthDisplay()
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
        closeOpenBudget()
        cachedBudgets = []
        remoteFilesByFileID = [:]
        invalidateNetworkTransports()
        bankSyncSessionCache.clear()
    }

    // Keep the authenticated budget list while switching databases.
    func closeOpenBudget() {
        database?.invalidateBankSyncWrites()
        budgetReadGeneration &+= 1
        pendingLocalMessageFlushTask?.cancel()
        pendingLocalMessageFlushTask = nil
        openedBudgetID = nil
        openedGroupID = nil
        openedNodeID = nil
        openedServerURLString = nil
        openedEncryptionContext = nil
        database = nil
        launchSnapshotFiles = nil
        launchSnapshotContext = nil
        accountsByBudget = [:]
        launchSnapshotWrittenRevision = nil
        accountGroupsByBudget = [:]
        accountGroupManagementEnabledByBudget = [:]
        payeesByBudget = [:]
        lastPayeeUndoMessagesByBudget = [:]
        actionLogDiagnosticSnapshot = .empty
        rulesByBudget = [:]
        monthsByBudget = [:]
        loadedBudgetMonthsByBudget = [:]
        templateBrowserByBudget = [:]
        accountTransactionsByKey = [:]
        spendingTransactionsByBudget = [:]
        categoryTransactionsByKey = [:]
        uncategorizedTransactionsByKey = [:]
        reportsByKey = [:]
        currencyByBudget = [:]
        bankSyncGenerationByAccount = [:]
        syncStatus = nil
        isFlushingPendingLocalMessages = false
        isDemoBudgetActive = false
        shouldFlushPendingLocalMessagesAgain = false
        resumePendingLocalMessageFlushWaiters()
    }

    func eraseLocalData() throws {
        reset()
        endpointHealth.clear()
        refreshEndpointHealthDisplay()
        try keychain.removeActualSyncToken()
        try keychain.removeAllLocalFirstEncryptionKeys()
        try keychain.removeSimpleFINAccessURL()
        try keychain.removeCustomHTTPHeaders()
        customHeadersRevision &+= 1
        try fileManager.deleteAllImportedBudgets()
    }

    func shouldSkipPrimary(primary: URL, fallback: URL) -> Bool {
        endpointHealth.shouldSkipPrimary(primary: primary, fallback: fallback)
    }

    func notePrimaryUnreachable(primary: URL, fallback: URL) {
        endpointHealth.notePrimaryUnreachable(primary: primary, fallback: fallback)
        refreshEndpointHealthDisplay()
    }

    func notePrimarySucceeded(primary: URL, fallback: URL) {
        endpointHealth.notePrimarySucceeded(primary: primary, fallback: fallback)
        refreshEndpointHealthDisplay()
    }

    func refreshEndpointHealthDisplay() {
        let endpoints = failoverEndpoints(for: openedServerURLString ?? "")
        endpointHealthDisplay = endpointHealth.display(
            currentPrimary: endpoints.primary,
            currentFallback: endpoints.fallback
        )
    }

    func syncStatus(budgetID: String) -> LocalFirstSyncStatus? {
        guard openedBudgetID == budgetID else {
            return nil
        }
        return syncStatus
    }

    func clearLastSyncError() {
        syncStatus?.lastError = nil
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
    static let localHTTPWarning = """
        This local HTTP connection is unencrypted. Your server password is sent during login, and your long-lived sync token is sent with every request. Anyone who can intercept traffic on this network can read both. Only continue on a trusted local network.
        """
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
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized == "localhost" {
            return true
        }
        if normalized.hasSuffix(".local") || normalized.hasSuffix(".ts.net") {
            return true
        }

        if let octets = ipv4Octets(normalized) {
            return isLocalIPv4(octets)
        }

        if let bytes = ipv6Bytes(normalized) {
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
                return true
            }
            if bytes[0] & 0xfe == 0xfc {
                return true
            }
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
                return true
            }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }),
               bytes[10] == 0xff,
               bytes[11] == 0xff {
                return isLocalIPv4(Array(bytes[12...15]))
            }
            return false
        }

        // Hostnames are classified lexically. Resolving here and allowing a private answer
        // would leave a DNS-rebinding window when URLSession resolves the hostname again.
        return false
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        guard let addressWithoutZoneSubstring = host.split(separator: "%", maxSplits: 1).first else {
            return nil
        }
        let addressWithoutZone = String(addressWithoutZoneSubstring)
        var address = in6_addr()
        guard inet_pton(AF_INET6, addressWithoutZone, &address) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else {
            return false
        }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 100 && (64...127).contains(octets[1]))
    }
}
