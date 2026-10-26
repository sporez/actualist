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
        preserving current: AdaptiveRootDestination?,
        accountPath: [ActualAccount] = []
    ) -> AdaptiveRootDestination {
        guard mode == .sidebar else {
            return AdaptiveRootDestination(tab: appTab)
        }
        if current == .settings { return .settings }
        if appTab == .accounts, let account = accountPath.last { return .account(account) }
        return AdaptiveRootDestination(tab: appTab)
    }
}

/// Sizes the root sidebar to its widest row label, within bounds the budget
/// layout can afford next to it.
enum AdaptiveSidebarWidth {
    static let minimum: CGFloat = 220
    static let maximum: CGFloat = 280
    /// List insets and row padding around a row's icon and title.
    static let rowChrome: CGFloat = 68

    static func ideal(forLabelWidth labelWidth: CGFloat) -> CGFloat {
        guard labelWidth.isFinite, labelWidth > 0 else { return BudgetLayoutMetrics.defaultSidebarWidth }
        return min(max(labelWidth.rounded(.up) + rowChrome, minimum), maximum)
    }
}
