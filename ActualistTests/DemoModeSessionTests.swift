import Foundation
import Security
import SwiftUI
import Testing
@testable import Actualist

@MainActor
struct DemoModeSessionTests {
    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        return defaults
    }

    private func makeSharedFileStorage() -> (fileManager: BudgetFileManager, keychain: KeychainStore) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ActualistDemoSession-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: root)
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        return (fileManager, keychain)
    }

    private func makeStore(
        fileManager: BudgetFileManager,
        keychain: KeychainStore,
        transport: ActualSyncTransport
    ) -> LocalFirstActualStore {
        LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: { _ in transport },
            connectionTransportFactory: { _ in StubConnectionTransport() }
        )
    }

    private func makeAppState(
        settingsStore: AppSettingsStore,
        keychain: KeychainStore,
        store: LocalFirstActualStore
    ) -> AppState {
        AppState(
            settingsStore: settingsStore,
            keychain: keychain,
            localFirstStore: store
        )
    }

    @Test func enterDemoModeRoutesToReadyWithoutServerContact() async throws {
        let transport = RecordingSyncTransport()
        let (fileManager, keychain) = makeSharedFileStorage()
        let settingsStore = AppSettingsStore(defaults: try makeDefaults())
        let state = makeAppState(
            settingsStore: settingsStore,
            keychain: keychain,
            store: makeStore(fileManager: fileManager, keychain: keychain, transport: transport)
        )

        #expect(state.setupPhase == .needsConnection)

        await state.enterDemoMode()

        #expect(state.setupPhase == .ready)
        #expect(state.isDemoMode)
        #expect(state.selectedBudget?.syncID == DemoBudget.groupID)
        #expect(state.settings.selectedBudgetID == DemoBudget.groupID)
        #expect(state.settings.selectedLocalFirstFileID == DemoBudget.fileID)
        #expect(state.settings.selectedLocalFirstGroupID == DemoBudget.groupID)
        #expect(state.settings.backgroundTransactionRefreshEnabled == false)
        #expect(state.connectionStatus == .offline)
        #expect(state.lastErrorMessage == nil)
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func onboardingDemoIntentEntersDemoMode() async throws {
        let transport = RecordingSyncTransport()
        let (fileManager, keychain) = makeSharedFileStorage()
        let settingsStore = AppSettingsStore(defaults: try makeDefaults())
        let state = makeAppState(
            settingsStore: settingsStore,
            keychain: keychain,
            store: makeStore(fileManager: fileManager, keychain: keychain, transport: transport)
        )

        let onboarding = OnboardingViewModel()
        await onboarding.enterDemo(using: state)

        #expect(state.setupPhase == .ready)
        #expect(state.isDemoMode)
        #expect(onboarding.isEnteringDemo == false)
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func launchRestoreFromDemoSelectionReachesReadyOffline() async throws {
        let transportA = RecordingSyncTransport()
        let transportB = RecordingSyncTransport()
        let (fileManager, keychain) = makeSharedFileStorage()
        let settingsStore = AppSettingsStore(defaults: try makeDefaults())

        // First app instance installs the demo budget and persists selection.
        let stateA = makeAppState(
            settingsStore: settingsStore,
            keychain: keychain,
            store: makeStore(fileManager: fileManager, keychain: keychain, transport: transportA)
        )
        await stateA.enterDemoMode()
        #expect(fileManager.importedDatabaseExists(fileID: DemoBudget.fileID))

        // A fresh app instance (new store over the same on-disk budget) restores
        // from the persisted demo selection on launch.
        let stateB = makeAppState(
            settingsStore: settingsStore,
            keychain: keychain,
            store: makeStore(fileManager: fileManager, keychain: keychain, transport: transportB)
        )
        #expect(stateB.setupPhase == .restoringBudget)

        await stateB.beginForegroundSession()

        #expect(stateB.setupPhase == .ready)
        #expect(stateB.isDemoMode)
        #expect(stateB.connectionStatus == .offline)
        #expect(stateB.lastErrorMessage == nil)
        #expect(await transportB.messageCounts().isEmpty)
    }

    @Test func pullToRefreshInDemoNeverTouchesTransportsOrSetsError() async throws {
        let transport = RecordingSyncTransport()
        let (fileManager, keychain) = makeSharedFileStorage()
        let settingsStore = AppSettingsStore(defaults: try makeDefaults())
        let state = makeAppState(
            settingsStore: settingsStore,
            keychain: keychain,
            store: makeStore(fileManager: fileManager, keychain: keychain, transport: transport)
        )
        await state.enterDemoMode()

        let succeeded = await state.refreshLocalFirstData(
            budgetID: DemoBudget.groupID,
            force: true
        )

        #expect(succeeded)
        #expect(state.lastErrorMessage == nil)
        #expect(state.connectionStatus != .connecting)
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func exitDemoModeReturnsToOnboardingAndCanBeReentered() async throws {
        let transport = RecordingSyncTransport()
        let (fileManager, keychain) = makeSharedFileStorage()
        let settingsStore = AppSettingsStore(defaults: try makeDefaults())
        let state = makeAppState(
            settingsStore: settingsStore,
            keychain: keychain,
            store: makeStore(fileManager: fileManager, keychain: keychain, transport: transport)
        )
        await state.enterDemoMode()
        #expect(state.isDemoMode)

        state.disconnectAndEraseLocalData()

        #expect(state.setupPhase == .needsConnection)
        #expect(!state.isDemoMode)
        #expect(state.lastErrorMessage == nil)
        #expect(!fileManager.importedDatabaseExists(fileID: DemoBudget.fileID))

        // The bundled artifact survives exit, so demo can be re-entered.
        await state.enterDemoMode()
        #expect(state.setupPhase == .ready)
        #expect(state.isDemoMode)
        #expect(fileManager.importedDatabaseExists(fileID: DemoBudget.fileID))
        #expect(await transport.messageCounts().isEmpty)
    }
}
