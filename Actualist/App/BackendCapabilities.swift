import Foundation

/// The single source of truth for what the backend can do right now.
///
/// Views and view models must consult these named flags instead of inspecting connection
/// state directly, so the read-only contract lives in one place. Local-first is the only
/// backend; these two flags stay constant today but keep the seam for the CRDT write phase:
/// - `isLocalFirst`: the native local-first sync backend is active (always true).
/// - `isReadOnly`: broad write surfaces are blocked while local-first mutations land in phases.
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

    // MARK: Write gates

    /// Create simple transactions. Local-first can expose this behind a developer gate while
    /// most of the write surface remains read-only.
    var canCreateTransactions: Bool { !isReadOnly || (isLocalFirst && allowsLocalFirstTransactionCreation) }
    /// Categorize existing uncategorized transactions. This is the first transaction mutation
    /// parity slice after create and uses the same developer write gate.
    var canCategorizeTransactions: Bool { !isReadOnly || (isLocalFirst && allowsLocalFirstTransactionCreation) }
    /// Update basic fields on a non-split, non-transfer transaction.
    var canUpdateSimpleTransactions: Bool { !isReadOnly || (isLocalFirst && allowsLocalFirstTransactionCreation) }
    /// Delete a non-split, non-transfer transaction via Actual tombstone semantics. Uses the
    /// same developer write gate as the other local-first transaction mutations.
    var canDeleteTransactions: Bool { !isReadOnly || (isLocalFirst && allowsLocalFirstTransactionCreation) }
    /// Create, edit, and delete transfer transactions (paired rows across two accounts). Uses
    /// the same developer write gate as the other local-first transaction mutations.
    var canWriteTransfers: Bool { !isReadOnly || (isLocalFirst && allowsLocalFirstTransactionCreation) }
    /// Create, edit, and delete split transactions (a parent with category children). Uses the
    /// same developer write gate as the other local-first transaction mutations.
    var canWriteSplits: Bool { !isReadOnly || (isLocalFirst && allowsLocalFirstTransactionCreation) }
    /// Assign budget, move money, and apply budget templates.
    var canAssignBudget: Bool { !isReadOnly }
    /// Edit and delete existing transactions.
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
