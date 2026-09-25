#if DEBUG
import Foundation
import Security
import Synchronization

/// UI-test-only Keychain backend. Never forwards requests to the device
/// Keychain, and never holds real credentials.
final class SyntheticCredentialFaultBackend: KeychainBackend, Sendable {
    private let blocked: Mutex<Bool>
    private let recoveryToken: String?

    init(blocked: Bool, recoveryToken: String? = nil) {
        self.blocked = Mutex(blocked)
        self.recoveryToken = recoveryToken
    }

    func recover() {
        blocked.withLock { $0 = false }
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        if blocked.withLock({ $0 }) { return errSecInteractionNotAllowed }
        guard let recoveryToken,
              (query as NSDictionary)[kSecAttrAccount as String] as? String == "synthetic-token" else {
            return errSecItemNotFound
        }
        result?.pointee = Data(recoveryToken.utf8) as AnyObject
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { errSecNotAvailable }
    func add(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus { errSecNotAvailable }
    func delete(_ query: CFDictionary) -> OSStatus { errSecItemNotFound }
}

@MainActor
enum SyntheticCredentialFaultHarness {
    private static let fileID = "synthetic-access-fixture"
    private static let groupID = "synthetic-access-group"

    static func make(arguments: [String]) -> AppState? {
        guard let index = arguments.firstIndex(of: "-actualist-test-credential-session"),
              arguments.indices.contains(index + 1),
              ["cached", "uncached", "onboarding"].contains(arguments[index + 1]) else {
            return nil
        }
        let mode = arguments[index + 1]
        let defaults = UserDefaults(suiteName: "ActualistSyntheticCredentialSession")!
        defaults.removePersistentDomain(forName: "ActualistSyntheticCredentialSession")
        let settingsStore = AppSettingsStore(defaults: defaults)
        if mode != "onboarding" {
            var settings = AppSettings(
                localFirstServerURLString: "https://synthetic.invalid",
                selectedBudgetID: groupID,
                selectedBudgetName: "Sample Budget",
                selectedLocalFirstFileID: fileID,
                selectedLocalFirstGroupID: groupID
            )
            if arguments.contains("light") { settings.theme = .actualPurpleLight }
            settingsStore.save(settings)
        }
        let backend = SyntheticCredentialFaultBackend(
            blocked: mode != "onboarding",
            recoveryToken: mode == "cached" ? "synthetic-recovery-token" : nil
        )
        let keychain = KeychainStore(
            service: "com.sporez.actualist.synthetic-session",
            account: "synthetic-token",
            backend: backend
        )
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SyntheticCredentialSession", directoryHint: .isDirectory)
        let files = BudgetFileManager(applicationSupportURL: root)
        if mode == "uncached" { try? files.deleteImportedBudget(fileID: fileID) }
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: files,
            syncTransportFactory: { _ in SyntheticCredentialSyncTransport() }
        )
        return AppState(
            settingsStore: settingsStore, keychain: keychain, localFirstStore: store,
            credentialRetryPreparation: { backend.recover() }
        )
    }

    static func prepareCacheIfRequested(arguments: [String], appState: AppState) async {
        guard arguments.contains("cached"),
              arguments.contains("-actualist-test-credential-session") else { return }
        let store = appState.localFirstStore
        let files = store.fileManager
        do {
            try await store.openDemoBudget()
            store.reset()
            try files.deleteImportedBudget(fileID: fileID)
            let directory = try files.budgetDirectory(fileID: fileID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: files.databaseURL(fileID: DemoBudget.fileID),
                to: files.databaseURL(fileID: fileID)
            )
            let metadata = LocalFirstBudgetMetadata(
                localBudgetID: fileID, cloudFileID: fileID, groupID: groupID,
                budgetName: "Sample Budget", encryptionKeyID: nil, nodeID: DemoBudget.nodeID
            )
            try JSONEncoder.actual.encode(metadata).write(to: files.metadataURL(fileID: fileID))
        } catch {
            appState.lastErrorMessage = "The synthetic UI fixture could not open."
        }
    }
}

private actor SyntheticCredentialSyncTransport: ActualSyncTransport {
    func sync(data: Data, token: String) async throws -> Data {
        guard token == "synthetic-recovery-token" else { throw LocalFirstError.missingSyncToken }
        return try ActualSync_SyncResponse().serializedData()
    }
}
#endif
