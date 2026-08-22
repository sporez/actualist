import Foundation
import Observation

@MainActor
@Observable
final class AppRouteCoordinator {
    private(set) var pendingRoute: AppRoute?

    func enqueue(_ route: AppRoute) {
        pendingRoute = route
    }

    @discardableResult
    func consume() -> AppRoute? {
        let route = pendingRoute
        pendingRoute = nil
        return route
    }

    func consume(if matches: (AppRoute) -> Bool) -> AppRoute? {
        guard let pendingRoute, matches(pendingRoute) else {
            return nil
        }
        return consume()
    }
}
