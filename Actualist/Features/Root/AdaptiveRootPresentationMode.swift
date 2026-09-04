import SwiftUI

private struct BudgetRootWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var budgetRootWidth: CGFloat {
        get { self[BudgetRootWidthKey.self] }
        set { self[BudgetRootWidthKey.self] = newValue }
    }
}

enum AdaptiveRootPresentationMode: Equatable {
    case compact
    case sidebar

    static func mode(for width: CGFloat, dynamicTypeScale: CGFloat = 1) -> Self {
        switch BudgetLayoutMetrics.resolve(
            BudgetLayoutInputs(rootWidth: width, dynamicTypeScale: dynamicTypeScale)
        ).presentationMode {
        case .compact: return .compact
        case .splitSingleMonth, .multiMonth: return .sidebar
        }
    }
}

enum AdaptiveRootTransition {
    static func selection(
        for mode: AdaptiveRootPresentationMode,
        appTab: AppTab,
        preserving current: AdaptiveRootDestination?
    ) -> AdaptiveRootDestination {
        guard mode == .sidebar else {
            return AdaptiveRootDestination(tab: appTab)
        }
        if current == .settings { return .settings }
        if case .account = current, appTab == .accounts {
            return current ?? .accounts
        }
        return AdaptiveRootDestination(tab: appTab)
    }
}
