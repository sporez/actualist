import Foundation
import Testing
@testable import Actualist

struct SimulatorLaunchCommandTests {
    @Test func absentFlagsAreIgnored() {
        #expect(SimulatorLaunchCommand.parse(arguments: ["/Actualist"]) == nil)
        #expect(SimulatorLaunchCommand.parse(arguments: ["/Actualist", "-AppleLanguages", "(en)"]) == nil)
    }

    @Test func parsesDemoAndKnownScreens() {
        let demo = SimulatorLaunchCommand.parse(arguments: ["/Actualist", "-actualist-demo"])
        #expect(demo?.enterDemo == true)
        #expect(demo?.screen == nil)
        #expect(demo?.route == .tab(.budget))

        let accounts = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-demo", "-actualist-screen", "Accounts"]
        )
        #expect(accounts?.enterDemo == true)
        #expect(accounts?.screen == .accounts)
        #expect(accounts?.route == .tab(.accounts))

        let settings = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-screen", "settings"]
        )
        #expect(settings?.enterDemo == false)
        #expect(settings?.route == .settings)

        let uncategorized = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-screen", "uncategorized"]
        )
        #expect(uncategorized?.route == .uncategorized(month: ""))
    }

    @Test func unknownScreenIsIgnored() {
        let command = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-demo", "-actualist-screen", "wallet"]
        )
        #expect(command?.enterDemo == true)
        #expect(command?.screen == nil)
    }
}

@MainActor
struct SimulatorLaunchApplierTests {
    @Test func demoFlagEntersDemoFromOnboardingAndSelectsTab() async throws {
        let transport = RecordingSyncTransport()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ActualistSimLaunch-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: root)
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: { _ in transport },
            connectionTransportFactory: { _ in StubConnectionTransport() }
        )
        let state = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: keychain,
            localFirstStore: store
        )
        #expect(state.setupPhase == .needsConnection)

        await SimulatorLaunchApplier.apply(
            SimulatorLaunchCommand(enterDemo: true, screen: .accounts),
            to: state
        )

        #expect(state.isDemoMode)
        #expect(state.setupPhase == .ready)
        #expect(state.selectedTab == .accounts)
        #expect(state.routeCoordinator.pendingRoute == .tab(.accounts))
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func demoFlagDoesNotEraseAReadyRealBudget() async {
        let defaults = UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)")
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults ?? .standard))
        state.setupPhase = .ready
        state.settings.selectedBudgetID = "real-budget"
        state.settings.selectedLocalFirstFileID = "real-file"

        await SimulatorLaunchApplier.apply(
            SimulatorLaunchCommand(enterDemo: true, screen: .spending),
            to: state
        )

        #expect(state.isDemoMode == false)
        #expect(state.settings.selectedBudgetID == "real-budget")
        #expect(state.selectedTab == .spending)
        #expect(state.routeCoordinator.pendingRoute == .tab(.spending))
    }
}
