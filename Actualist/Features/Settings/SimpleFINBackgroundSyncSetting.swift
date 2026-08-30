import Foundation
import Observation

/// Screen state for the Background Bank Sync toggle (plan Phase 6).
/// Probes whether the connected server provides SimpleFIN so the toggle can
/// be disabled with an explanation instead of failing silently in the
/// background. Demo mode and a missing budget never probe.
@MainActor
@Observable
final class SimpleFINBackgroundSyncSetting {
    private(set) var serverSupport: SimpleFINServerSupport?
    private(set) var didProbe = false

    /// The toggle can only be enabled when the server serves SimpleFIN.
    var canEnable: Bool {
        serverSupport == .configured
    }

    func load(store: LocalFirstActualStore, budgetID: String?, isDemoMode: Bool) async {
        guard !isDemoMode, let budgetID, store.isOpen(budgetID: budgetID) else {
            serverSupport = nil
            didProbe = true
            return
        }
        serverSupport = try? await store.bankSyncSupport(budgetID: budgetID)
        didProbe = true
    }
}
