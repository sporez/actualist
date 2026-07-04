import Foundation

/// The single source of truth for what the active backend can do right now.
///
/// Views and view models must consult these named flags instead of reading
/// `backendMode`/connection state directly, so the read-only contract lives in one place.
/// Two orthogonal facts drive every flag:
/// - `isLocalFirst`: the native local-first sync backend is active (permanently read-only in v1).
/// - `isReadOnly`: no write may be attempted right now — always true in local-first, and
///   transiently true when a REST session is offline.
struct BackendCapabilities: Equatable {
    let isLocalFirst: Bool
    let isReadOnly: Bool

    // MARK: Write gates (blocked whenever read-only, including a REST session that is offline)

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

    // MARK: Structural gates (feature is entirely absent in local-first, not merely disabled)

    /// The Add Account affordance is offered at all (hidden in local-first).
    var showsAddAccount: Bool { !isLocalFirst }
    /// Add Account can be tapped (hidden in local-first, disabled while a REST session is offline).
    var canAddAccount: Bool { !isLocalFirst && !isReadOnly }
    /// Background transaction refresh runs for this backend.
    var supportsBackgroundRefresh: Bool { !isLocalFirst }
    /// New-transaction notifications are posted and routed for this backend.
    var supportsTransactionNotifications: Bool { !isLocalFirst }
}
