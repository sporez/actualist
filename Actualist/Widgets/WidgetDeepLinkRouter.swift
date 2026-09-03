import Foundation

enum WidgetDeepLinkRouter {
    @MainActor
    static func handle(_ url: URL, appState: AppState) {
        guard let link = WidgetDeepLink.parse(url) else {
            return
        }
        switch link {
        case .category(let id, let month):
            appState.accountNavigationPath = []
            appState.selectedTab = .budget
            appState.routeCoordinator.enqueue(.category(id: id, month: month))
        }
    }
}
