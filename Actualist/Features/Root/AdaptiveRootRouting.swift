import Foundation

/// Root activation reveals a feature without consuming its payload.
enum AdaptiveRootRouting {
    static func destination(for route: AppRoute, accounts: [ActualAccount]) -> AdaptiveRootDestination? {
        switch route {
        case .tab(let tab): AdaptiveRootDestination(tab: tab)
        case .account(let id): accounts.first { $0.id == id }.map(AdaptiveRootDestination.account)
        case .category, .uncategorized, .history: .budget
        case .settings: .settings
        case .newTransaction: nil
        }
    }

    @MainActor
    static func activate(_ destination: AdaptiveRootDestination, using appState: AppState, mode: AdaptiveRootPresentationMode = .compact) {
        if let tab = destination.appTab { appState.selectedTab = tab }
        switch destination {
        case .accounts: appState.accountNavigationPath = []
        case .account(let account) where mode == .compact: appState.accountNavigationPath = [account]
        default: break
        }
    }

    @MainActor
    static func applyPending(using appState: AppState, accounts: [ActualAccount], mode: AdaptiveRootPresentationMode = .compact) -> AdaptiveRootDestination? {
        guard let route = appState.routeCoordinator.pendingRoute,
              let destination = destination(for: route, accounts: accounts) else { return nil }
        activate(destination, using: appState, mode: mode)
        switch route {
        case .tab, .account, .settings:
            _ = appState.routeCoordinator.consume(if: { $0 == route })
        default: break
        }
        return destination
    }
}
