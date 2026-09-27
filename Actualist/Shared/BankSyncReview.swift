import Foundation

/// Persisted ownership captured before requesting a bank download.
struct BankSyncLinkIdentity: Equatable, Sendable {
    let storageID: String
    let accountID: String
    let remoteAccountID: String
    let syncSource: String
}

/// Immutable download plans and apply outcomes. The store validates each plan
/// before writing; the feature renders saved effects and blocked accounts.
enum BankSyncReview {
    /// Exact account-balance effect of applying a download. A successful
    /// download either replaces or clears stale bank evidence; a failed
    /// download leaves the prior value untouched.
    enum BalanceDisposition: Equatable, Sendable {
        case set(Int)
        case clear
        case preserve
    }

    /// A downloaded row that could not be normalized (junk amount, missing
    /// date). Never silently dropped: surfaced as a problem row.
    struct Problem: Equatable, Sendable {
        let remoteTransactionID: String?
        let message: String

        static let invalidCustomMapping = Problem(
            remoteTransactionID: nil,
            message: "Custom bank field mapping is invalid. This download was not imported."
        )

        static func unsupportedAccountMove(remoteTransactionID: String?) -> Problem {
            Problem(
                remoteTransactionID: remoteTransactionID,
                message: "A rule moves this transaction to another account. This Bank Sync build cannot apply that safely."
            )
        }

        static func missingMappingSide(
            remoteTransactionID: String?,
            isPayment: Bool
        ) -> Problem {
            Problem(
                remoteTransactionID: remoteTransactionID,
                message: isPayment
                    ? "Custom field mapping is missing the payment fields."
                    : "Custom field mapping is missing the deposit fields."
            )
        }
    }

    /// Exact user-visible effects of one matched transaction. This snapshot
    /// is assembled from the same `MatchedUpdate` the store applies, so
    /// result details never guess from aggregate counts.
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

    /// One linked account's planned writes, including its opening balance.
    struct AccountPlan: Equatable, Sendable {
        let link: BankSyncLinkIdentity
        let durableStatus: ActualBankSyncDurableStatus
        let inserts: [BankSyncReconciliation.Candidate]
        let updates: [BankSyncReconciliation.MatchedUpdate]
        let matchDetails: [MatchDetail]
        let unchangedCount: Int
        let problems: [Problem]
        let openingBalance: BankSyncReconciliation.OpeningBalance?
        let balanceDisposition: BalanceDisposition

        /// Unique token captured before this download starts. A stale
        /// plan (a newer download happened since) is refused at apply time.
        let generation: UUID
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

/// The account committed atomically, but its local display refresh failed.
/// Carries the actual outcome so a stopped run retains its saved counts.
struct BankSyncCommittedRefreshError: LocalizedError {
    let result: BankSyncReview.ApplyResult
    let underlyingError: any Error

    var errorDescription: String? {
        "Changes were saved locally, but the display could not refresh. Sync again to refresh and continue."
    }
}

/// Outcome of the Phase 6 background bank-sync step: how many linked
/// accounts were applied and which transactions were inserted, keyed by
/// local account. Pure value passed to the background workflow.
struct BankSyncBackgroundApplyResult: Equatable, Sendable {
    let accountCount: Int
    let insertedTransactionIDsByAccount: [String: [String]]
}
