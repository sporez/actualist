import Foundation

/// Review DTO between a confirmed SimpleFIN download and the apply step
/// (plan Phase 3). Pure: assembled by the store from the reconciler plan,
/// shown by the Phase 4 review sheet, and written only after an explicit
/// confirm. Cancel / staleness simply discards the value — no rows, no
/// `last_sync`.
enum BankSyncReview {
    /// A downloaded row that could not be normalized (junk amount, missing
    /// date). Never silently dropped: surfaced as a problem row.
    struct Problem: Equatable, Sendable {
        let remoteTransactionID: String?
        let message: String
    }

    /// Exact user-visible effects of one matched transaction. This snapshot
    /// is assembled from the same `MatchedUpdate` that Confirm will apply, so
    /// review copy never guesses from aggregate counts.
    struct MatchDetail: Equatable, Sendable {
        let transactionID: String
        let dayID: String
        let amountMinorUnits: Int
        let currentPayeeName: String?
        let changes: [MatchChange]
    }

    struct MatchChange: Equatable, Sendable {
        enum Field: Equatable, Sendable {
            case bankIDAttached
            case bankIDReplaced
            case payee
            case category
            case bankPayee
            case notes
            case cleared
            case splitChildrenCleared
        }

        let field: Field
        let oldValue: String?
        let newValue: String?
    }

    /// One linked account's planned writes. `openingBalance` counts as an
    /// added row on the review sheet.
    struct AccountPlan: Equatable, Sendable {
        let accountID: String
        let remoteAccountID: String
        let durableStatus: ActualBankSyncDurableStatus
        let inserts: [BankSyncReconciliation.Candidate]
        let updates: [BankSyncReconciliation.MatchedUpdate]
        let matchDetails: [MatchDetail]
        let unchangedCount: Int
        let problems: [Problem]
        let openingBalance: BankSyncReconciliation.OpeningBalance?

        /// Monotonic token captured when this plan was downloaded. A stale
        /// plan (a newer download happened since) is refused at apply time.
        let generation: Int

        var hasWrites: Bool {
            !inserts.isEmpty || !updates.isEmpty || openingBalance != nil
        }
    }

    struct ApplyResult: Equatable, Sendable {
        let insertedCount: Int
        let updatedCount: Int
        let openingBalanceInserted: Bool
        /// Local IDs of the inserted transaction parents (and opening
        /// balance), so the background path can feed the existing
        /// new-transaction notification pipeline.
        let insertedTransactionIDs: [String]
    }
}

/// Outcome of the Phase 6 background bank-sync step: how many linked
/// accounts were applied and which transactions were inserted, keyed by
/// local account. Pure value passed to the background workflow.
struct BankSyncBackgroundApplyResult: Equatable, Sendable {
    let accountCount: Int
    let insertedTransactionIDsByAccount: [String: [String]]
}
