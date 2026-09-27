import Foundation
import Observation

@MainActor
@Observable
final class AppRouteCoordinator {
    private(set) var pendingRoute: AppRoute?
    private(set) var pendingAccountLifecycleReceipt: AccountLifecycleRouteReceipt?

    var readyAccountLifecycleReceiptID: UUID? {
        guard let receipt = pendingAccountLifecycleReceipt,
              !receipt.awaitsSavedNoticeDismissal else { return nil }
        return receipt.id
    }
    var settingsPath: [SettingsPage] = []
    private var settingsPresentation: SettingsPresentation = .hidden

    private enum SettingsPresentation {
        case hidden
        case visible
        case dismissing((@MainActor () -> Void)?)
    }

    var isSettingsPresented: Bool {
        if case .visible = settingsPresentation { return true }
        return false
    }

    func presentSettings(path: [SettingsPage]? = nil) {
        if let path { settingsPath = path }
        settingsPresentation = .visible
    }

    func setSettingsPresented(_ presented: Bool) {
        if presented {
            presentSettings()
        } else if case .visible = settingsPresentation {
            settingsPresentation = .dismissing(nil)
        }
    }

    func afterDismissingSettings(_ navigate: @escaping @MainActor () -> Void) {
        switch settingsPresentation {
        case .hidden:
            navigate()
        case .visible, .dismissing:
            settingsPresentation = .dismissing(navigate)
        }
    }

    func settingsDidDismiss() {
        guard case .dismissing(let navigate) = settingsPresentation else { return }
        settingsPresentation = .hidden
        navigate?()
    }

    /// A width handoff removes the compact cover host; no UIKit dismissal
    /// callback remains to release a queued widget navigation.
    func settingsHostRemoved() {
        if case .dismissing(let navigate) = settingsPresentation {
            settingsPresentation = .hidden
            navigate?()
        } else {
            settingsPresentation = .hidden
        }
    }

    /// A session teardown (disconnect, erase, sign-in-again) removes every
    /// settings host without a SwiftUI dismissal callback. Drop the queued
    /// continuation too: it navigates toward state the teardown destroyed.
    func reset() {
        pendingRoute = nil
        pendingAccountLifecycleReceipt = nil
        settingsPath = []
        settingsPresentation = .hidden
    }

    func enqueue(_ route: AppRoute) {
        pendingRoute = route
    }

    func publishAccountLifecycleReceipt(_ receipt: AccountLifecycleRouteReceipt) {
        pendingAccountLifecycleReceipt = receipt
    }

    func consumeAccountLifecycleReceipt(id: UUID) -> AccountLifecycleRouteReceipt? {
        guard let receipt = pendingAccountLifecycleReceipt,
              receipt.id == id, !receipt.awaitsSavedNoticeDismissal else { return nil }
        pendingAccountLifecycleReceipt = nil
        return receipt
    }

    func accountLifecycleSavedNoticeDismissed(receiptID: UUID) {
        guard pendingAccountLifecycleReceipt?.id == receiptID else { return }
        pendingAccountLifecycleReceipt?.awaitsSavedNoticeDismissal = false
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
