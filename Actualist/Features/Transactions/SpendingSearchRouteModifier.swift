import SwiftUI

extension View {
    /// Hands a pending `.spendingSearch` route to the Spending feed exactly
    /// once. Activation (tab or sidebar selection) leaves the route pending,
    /// so the feed consumes it whether it was already visible or appears later.
    /// The route is consumed only when `apply` accepts it; a feed without its
    /// budget yet (cold launch, budget switch) retries when `budgetID` changes.
    func onSpendingSearchRoute(
        isSpendingFeed: Bool,
        budgetID: String?,
        apply: @escaping @MainActor (String) -> Bool
    ) -> some View {
        modifier(SpendingSearchRouteModifier(isSpendingFeed: isSpendingFeed, budgetID: budgetID, apply: apply))
    }
}

private struct SpendingSearchRouteModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    let isSpendingFeed: Bool
    let budgetID: String?
    let apply: @MainActor (String) -> Bool

    func body(content: Content) -> some View {
        content
            .onAppear(perform: consume)
            .onChange(of: appState.routeCoordinator.pendingRoute) { consume() }
            .onChange(of: budgetID) { consume() }
    }

    private func consume() {
        guard isSpendingFeed,
              let route = appState.routeCoordinator.pendingRoute,
              let query = AppRouteApplication.spendingSearchQuery(from: route),
              apply(query) else { return }
        _ = appState.routeCoordinator.consume(if: { $0 == route })
    }
}
