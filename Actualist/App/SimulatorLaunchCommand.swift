import Foundation

/// Process-launch flags for agent-driven simulator verification.
///
/// Parsed from `ProcessInfo` arguments. Absent flags mean a normal user launch.
/// `-actualist-demo` installs the bundled demo budget only from onboarding; it
/// never erases a real selected budget. Use the simulator helper `--reset` for
/// a clean install.
///
/// `-actualist-screen` takes a slash path, not a closed enum. Roots are tabs,
/// `settings`, `history`, and `uncategorized`. Nested settings pages use the
/// `SettingsPage` slug (`settings/appearance`). Unique slugs also work as
/// shorthand (`appearance`). Unknown paths are kept but do not change routing.
struct SimulatorLaunchCommand: Equatable, Sendable {
    var enterDemo = false
    var screenPath: [String] = []

    var isEmpty: Bool {
        !enterDemo && screenPath.isEmpty
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
                guard next < arguments.endIndex else {
                    index = arguments.index(after: index)
                    continue
                }
                let path = Self.path(from: arguments[next])
                if !path.isEmpty {
                    command.screenPath = path
                }
                index = next
            }
            index = arguments.index(after: index)
        }
        return command.isEmpty ? nil : command
    }

    static func path(from rawValue: String) -> [String] {
        rawValue
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func fromProcessInfo(
        _ processInfo: ProcessInfo = .processInfo
    ) -> SimulatorLaunchCommand? {
        parse(arguments: processInfo.arguments)
    }

    var route: AppRoute? {
        guard let first = screenPath.first else {
            return enterDemo ? .tab(.budget) : nil
        }
        if let tab = AppTab(rawValue: first) {
            return .tab(tab)
        }
        if first == "uncategorized" {
            return .uncategorized(month: "")
        }
        if first == "history" {
            return .history
        }
        if first == "settings" || SettingsPage(rawValue: first) != nil {
            return .settings
        }
        return enterDemo ? .tab(.budget) : nil
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
        case .category, .uncategorized, .history, .settings:
            appState.selectedTab = .budget
        case .newTransaction:
            break
        }
        appState.routeCoordinator.enqueue(route)
    }
}
