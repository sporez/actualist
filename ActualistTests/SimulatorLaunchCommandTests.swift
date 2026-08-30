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
        #expect(demo?.screenPath == [])
        #expect(demo?.route == .tab(.budget))

        let accounts = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-demo", "-actualist-screen", "Accounts"]
        )
        #expect(accounts?.enterDemo == true)
        #expect(accounts?.screenPath == ["accounts"])
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

    @Test func parsesSlashPathsAndSettingsShorthand() {
        let nested = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-screen", "settings/appearance"]
        )
        #expect(nested?.screenPath == ["settings", "appearance"])
        #expect(nested?.route == .settings)
        #expect(SettingsPage.stack(fromScreenPath: nested?.screenPath ?? []) == [.appearance])

        let shorthand = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-screen", "Privacy"]
        )
        #expect(shorthand?.screenPath == ["privacy"])
        #expect(shorthand?.route == .settings)
        #expect(SettingsPage.stack(fromScreenPath: shorthand?.screenPath ?? []) == [.privacy])

        let reportsTab = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-screen", "reports"]
        )
        let reportsTabStack = SettingsPage.stack(fromScreenPath: reportsTab?.screenPath ?? [])
        #expect(reportsTab?.route == .tab(.reports))
        #expect(reportsTabStack == [])

        let reportsSettings = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-screen", "settings/reports"]
        )
        #expect(reportsSettings?.route == .settings)
        #expect(SettingsPage.stack(fromScreenPath: reportsSettings?.screenPath ?? []) == [.reports])
    }

    @Test func bankSyncLaunchPathIsDroppedWhenExperimentalIsOff() {
        let path = ["settings", "budget-data", "bank-sync"]
        #expect(
            SettingsPage.stack(fromScreenPath: path, isBankSyncEnabled: true)
                == [.budgetData, .bankSync]
        )
        #expect(
            SettingsPage.stack(fromScreenPath: path, isBankSyncEnabled: false)
                == [.budgetData]
        )
        #expect(
            SettingsPage.stack(fromScreenPath: ["bank-sync"], isBankSyncEnabled: false).isEmpty
        )
    }

    @Test func unknownScreenKeepsDemoRoute() {
        let command = SimulatorLaunchCommand.parse(
            arguments: ["/Actualist", "-actualist-demo", "-actualist-screen", "wallet"]
        )
        let unknownStack = SettingsPage.stack(fromScreenPath: command?.screenPath ?? [])
        #expect(command?.enterDemo == true)
        #expect(command?.screenPath == ["wallet"])
        #expect(command?.route == .tab(.budget))
        #expect(unknownStack == [])
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
            SimulatorLaunchCommand(enterDemo: true, screenPath: ["accounts"]),
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
            SimulatorLaunchCommand(enterDemo: true, screenPath: ["spending"]),
            to: state
        )

        #expect(state.isDemoMode == false)
        #expect(state.settings.selectedBudgetID == "real-budget")
        #expect(state.selectedTab == .spending)
        #expect(state.routeCoordinator.pendingRoute == .tab(.spending))
    }
}
