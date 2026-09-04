import Foundation

enum WidgetDeepLinkRouter {
    @MainActor
    static func handle(_ url: URL, appState: AppState) {
        guard let link = WidgetDeepLink.parse(url) else {
            return
        }
        switch link {
        case .account(let id):
            appState.routeCoordinator.afterDismissingSettings { [weak appState] in
                guard let appState else { return }
                appState.accountNavigationPath = []
                appState.selectedTab = .accounts
                appState.routeCoordinator.enqueue(.account(id: id))
            }
        case .quickAction(let action):
            let destination = WidgetQuickActionRoute(action: action)
            appState.routeCoordinator.afterDismissingSettings { [weak appState] in
                guard let appState else { return }
                apply(destination, to: appState)
            }
        case .category(let id, let month):
            appState.routeCoordinator.afterDismissingSettings { [weak appState] in
                guard let appState else { return }
                appState.accountNavigationPath = []
                appState.selectedTab = .budget
                appState.routeCoordinator.enqueue(.category(id: id, month: month))
            }
        }
    }

    @MainActor
    private static func apply(_ destination: WidgetQuickActionRoute, to appState: AppState) {
        appState.accountNavigationPath = []
        appState.selectedTab = destination.tab
        appState.routeCoordinator.settingsPath = destination.settingsPage.map { [$0] } ?? []
        appState.routeCoordinator.enqueue(destination.route)
    }
}
