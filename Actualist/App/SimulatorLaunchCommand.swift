import Foundation

/// Process-launch flags for agent-driven simulator verification.
///
/// Parsed from `ProcessInfo` arguments. Absent flags mean a normal user launch.
/// `-actualist-demo` installs the bundled demo budget only from onboarding; it
/// never erases a real selected budget. Use the simulator helper `--reset` for
/// a clean install.
struct SimulatorLaunchCommand: Equatable, Sendable {
    enum Screen: String, CaseIterable, Sendable {
        case budget
        case spending
        case accounts
        case reports
        case settings
        case uncategorized
    }

    var enterDemo = false
    var screen: Screen?

    var isEmpty: Bool {
        !enterDemo && screen == nil
    }

    static func parse(arguments: [String]) -> SimulatorLaunchCommand? {
        var command = SimulatorLaunchCommand()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "-actualist-demo" {
                command.enterDemo = true
            } else if argument == "-actualist-screen" {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex,
                      let screen = Screen(rawValue: arguments[next].lowercased()) else {
                    index = arguments.index(after: index)
                    continue
                }
                command.screen = screen
                index = next
            }
            index = arguments.index(after: index)
        }
        return command.isEmpty ? nil : command
    }

    static func fromProcessInfo(
        _ processInfo: ProcessInfo = .processInfo
    ) -> SimulatorLaunchCommand? {
        parse(arguments: processInfo.arguments)
    }

    var route: AppRoute? {
        switch screen {
        case .budget:
            .tab(.budget)
        case .spending:
            .tab(.spending)
        case .accounts:
            .tab(.accounts)
        case .reports:
            .tab(.reports)
        case .settings:
            .settings
        case .uncategorized:
            .uncategorized(month: "")
        case nil:
            enterDemo ? .tab(.budget) : nil
        }
    }
}

@MainActor
enum SimulatorLaunchApplier {
    static func apply(_ command: SimulatorLaunchCommand, to appState: AppState) async {
        if command.enterDemo, appState.setupPhase == .needsConnection {
            await appState.enterDemoMode()
        }

        guard let route = command.route else {
            return
        }

        appState.accountNavigationPath = []
        switch route {
        case .tab(let tab):
            appState.selectedTab = tab
        case .account:
            appState.selectedTab = .accounts
        case .category, .uncategorized, .settings:
            appState.selectedTab = .budget
        case .newTransaction:
            break
        }
        appState.routeCoordinator.enqueue(route)
    }
}
