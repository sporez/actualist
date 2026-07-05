import Foundation

/// The single source of truth for what the backend can do right now.
///
/// Views and view models must consult these named flags instead of inspecting connection
/// state directly, so the read-only contract lives in one place. Local-first is the only
/// backend; these two flags stay constant today but keep the seam for the CRDT write phase:
/// - `isLocalFirst`: the native local-first sync backend is active (always true).
/// - `isReadOnly`: no write may be attempted right now — always true until CRDT writes land.
struct BackendCapabilities: Equatable {
    let isLocalFirst: Bool
    let isReadOnly: Bool

    // MARK: Write gates (blocked whenever read-only)

    /// Assign budget, move money, and apply budget templates.
    var canAssignBudget: Bool { !isReadOnly }
    /// Create, edit, delete, and categorize transactions.
    var canEditTransactions: Bool { !isReadOnly }
    /// Trigger a bank sync for a linked account.
    var canBankSync: Bool { !isReadOnly }
    /// Reconcile an account balance.
    var canReconcile: Bool { !isReadOnly }
    /// Preview and apply rules.
    var canApplyRules: Bool { !isReadOnly }

    // MARK: Structural gates

    /// Whether the Add Account affordance is offered at all (hidden until re-enabled locally).
    var showsAddAccount: Bool { !isLocalFirst }
    /// Add Account can be tapped.
    var canAddAccount: Bool { !isLocalFirst && !isReadOnly }
    /// Background transaction refresh is read-only in local-first: pull sync, diff rows, alert.
    var supportsBackgroundRefresh: Bool { true }
    /// New-transaction notifications are posted and routed after a read-only local-first sync.
    var supportsTransactionNotifications: Bool { true }
}
