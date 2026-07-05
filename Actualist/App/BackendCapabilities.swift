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
    let allowsLocalFirstTransactionCreation: Bool

    init(
        isLocalFirst: Bool,
        isReadOnly: Bool,
        allowsLocalFirstTransactionCreation: Bool = false
    ) {
        self.isLocalFirst = isLocalFirst
        self.isReadOnly = isReadOnly
        self.allowsLocalFirstTransactionCreation = allowsLocalFirstTransactionCreation
    }

    // MARK: Write gates (blocked whenever read-only)

    /// Create simple transactions. Local-first can expose this behind a developer gate while
    /// the rest of the write surface remains read-only.
    var canCreateTransactions: Bool { !isReadOnly || (isLocalFirst && allowsLocalFirstTransactionCreation) }
    /// Assign budget, move money, and apply budget templates.
    var canAssignBudget: Bool { !isReadOnly }
    /// Edit, delete, and categorize existing transactions.
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
