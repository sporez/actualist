/// The single source of truth for what the backend can do right now.
///
/// Views and view models consult these named capabilities so unsupported mutations stay
/// unavailable without putting proven local-first writes behind a user or developer setting.
struct BackendCapabilities: Equatable {
    static let localFirst = BackendCapabilities()

    private init() {}

    // MARK: Supported writes

    /// Create simple transactions through the native CRDT/outbox path.
    var canCreateTransactions: Bool { true }
    /// Categorize existing uncategorized transactions.
    var canCategorizeTransactions: Bool { true }
    /// Update basic fields on a non-split, non-transfer transaction.
    var canUpdateSimpleTransactions: Bool { true }
    /// Delete a non-split, non-transfer transaction via Actual tombstone semantics.
    var canDeleteTransactions: Bool { true }
    /// Create, edit, and delete paired transfer transactions.
    var canWriteTransfers: Bool { true }
    /// Create, edit, and delete split transaction parents and children.
    var canWriteSplits: Bool { true }
    /// Assign a category's budgeted amount.
    var canAssignCategoryBudget: Bool { true }
    /// Carry a category's negative balance forward from the selected month.
    var canSetCategoryCarryover: Bool { true }
    /// Move money between categories and To Budget.
    var canMoveMoney: Bool { true }
    /// The fixed-amount template mutation exists, but product exposure remains experimental.
    var canApplyBudgetTemplates: Bool { true }
    /// Broad compatibility capability for implemented budget write surfaces.
    var canAssignBudget: Bool {
        canAssignCategoryBudget || canSetCategoryCarryover || canMoveMoney || canApplyBudgetTemplates
    }
    /// Create an account and its linked transfer payee.
    var canAddAccount: Bool { true }

    // MARK: Unsupported writes

    /// Reconciliation does not yet have a native local-first mutation.
    var canReconcile: Bool { false }
    /// Rule preview/apply does not yet have a native local-first implementation.
    var canApplyRules: Bool { false }

    // MARK: Structural capabilities

    var showsAddAccount: Bool { canAddAccount }
    /// Background refresh pulls sync messages, diffs rows, and posts alerts.
    var supportsBackgroundRefresh: Bool { true }
    /// New-transaction notifications are posted and routed after a local-first sync.
    var supportsTransactionNotifications: Bool { true }
}
