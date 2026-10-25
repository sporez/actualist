import AppIntents
import Foundation

/// iOS 27 Siri AI finds this by schema, so it is not an App Shortcut and has
/// no phrases. It opens Spending with the spoken query in the search field.
@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchSpendingIntent: ShowInAppSearchResultsIntent, ActualistForegroundIntent {
    static var searchScopes: [StringSearchScope] { [.general] }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    var criteria: StringSearchCriteria

    @Dependency
    var session: ShortcutsBudgetSession

    func perform() async throws -> some IntentResult {
        try await session.enqueueRoute(AppRouteApplication.spendingRoute(searchTerm: criteria.term))
        return .result()
    }
}
