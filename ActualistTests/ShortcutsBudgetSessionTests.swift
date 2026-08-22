import Foundation
import Security
import Testing
@testable import Actualist

@MainActor
struct ShortcutsBudgetSessionTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func alreadyOpenStoreIsReused() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let session = ShortcutsBudgetSession(appState: appState)

        let prepared = try await session.prepare()

        #expect(prepared.budgetID == "group-1")
        #expect(prepared.store === bundle.store)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
    }

    @Test func coldOpenReusesCachedBudgetWithoutContactingServer() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle { _ in transport }
        let appState = try fixtures.makeAppState(for: bundle)
        bundle.store.reset()
        #expect(!bundle.store.isOpen(budgetID: "group-1"))

        let session = ShortcutsBudgetSession(appState: appState)
        let prepared = try await session.prepare()

        #expect(prepared.budgetID == "group-1")
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func disabledShortcutsRefuseEveryAction() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        appState.updateShortcutsEnabled(false)
        let session = ShortcutsBudgetSession(appState: appState)

        await #expect(throws: ShortcutsError.shortcutsDisabled) {
            try await session.prepare()
        }
        #expect(bundle.store.isOpen(budgetID: "group-1"))
    }

    @Test func missingBudgetSelectionFailsCleanly() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let appState = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        let session = ShortcutsBudgetSession(appState: appState)

        #expect(appState.setupPhase == .needsConnection)
        await #expect(throws: ShortcutsError.noBudgetSelected) {
            try await session.prepare()
        }
    }

    @Test func missingBudgetFileFailsWithoutOpeningASecondDatabase() async throws {
        let transport = RecordingSyncTransport()
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.save(
            AppSettings(
                selectedBudgetID: "group-missing",
                selectedBudgetName: "Missing Budget",
                selectedLocalFirstFileID: "file-missing",
                selectedLocalFirstGroupID: "group-missing"
            )
        )
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: BudgetFileManager(
                applicationSupportURL: FileManager.default.temporaryDirectory
                    .appending(path: "ActualistMissingBudget-\(UUID().uuidString)", directoryHint: .isDirectory)
            ),
            syncTransportFactory: { _ in transport },
            connectionTransportFactory: { _ in StubConnectionTransport() }
        )
        let appState = AppState(
            settingsStore: settingsStore,
            keychain: keychain,
            localFirstStore: store
        )
        let session = ShortcutsBudgetSession(appState: appState)

        await #expect(throws: ShortcutsError.budgetFileMissing) {
            try await session.prepare()
        }
        #expect(!store.hasOpenBudget)
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func demoBudgetOpensFromTheLocalCache() async throws {
        let transport = RecordingSyncTransport()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ActualistShortcutsDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: root)
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: { _ in transport },
            connectionTransportFactory: { _ in StubConnectionTransport() }
        )
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let appState = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: keychain,
            localFirstStore: store
        )
        await appState.enterDemoMode()
        #expect(store.isOpen(budgetID: DemoBudget.groupID))
        store.reset()
        #expect(!store.isOpen(budgetID: DemoBudget.groupID))

        let session = ShortcutsBudgetSession(appState: appState)
        let prepared = try await session.prepare()

        #expect(prepared.budgetID == DemoBudget.groupID)
        #expect(store.isOpen(budgetID: DemoBudget.groupID))
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func encryptedBudgetWithoutUnlockFailsCleanly() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        bundle.store.closeOpenBudget()
        let encryptedMetadata = LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "group-1",
            budgetName: "Writable Budget",
            encryptionKeyID: "key-shortcuts-\(UUID().uuidString)",
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(encryptedMetadata).write(
            to: bundle.fileManager.metadataURL(fileID: "file-1")
        )

        let session = ShortcutsBudgetSession(appState: appState)
        await #expect(throws: ShortcutsError.encryptedBudgetNeedsUnlock) {
            try await session.prepare()
        }
        #expect(!bundle.store.hasOpenBudget)
    }

    @Test func openBudgetMismatchDoesNotResetTheLiveStore() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        appState.settings.selectedBudgetID = "group-2"
        appState.settings.selectedLocalFirstFileID = "file-2"
        let session = ShortcutsBudgetSession(appState: appState)

        await #expect(throws: ShortcutsError.budgetBusy) {
            try await session.prepare()
        }
        #expect(bundle.store.isOpen(budgetID: "group-1"))
    }

    @Test func successfulWriteBumpsLocalDataRevision() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let session = ShortcutsBudgetSession(appState: appState)
        try await session.prepare()
        let before = appState.localDataRevision

        session.recordSuccessfulWrite()

        #expect(appState.localDataRevision == before + 1)
    }
}
