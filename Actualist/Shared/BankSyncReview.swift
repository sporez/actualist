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

    /// One linked account's planned writes. `openingBalance` counts as an
    /// added row on the review sheet.
    struct AccountPlan: Equatable, Sendable {
        let accountID: String
        let remoteAccountID: String
        let durableStatus: ActualBankSyncDurableStatus
        let inserts: [BankSyncReconciliation.Candidate]
        let updates: [BankSyncReconciliation.MatchedUpdate]
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
    }
}
