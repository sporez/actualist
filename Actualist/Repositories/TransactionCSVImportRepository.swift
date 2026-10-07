import Foundation

/// Import-stage options. The parser supports any single-character delimiter
/// and headerless files; the review UI currently exposes the defaults only.
struct TransactionCSVImportOptions: Sendable, Equatable {
    var delimiter: String
    var hasHeaderRow: Bool

    init(delimiter: String = ",", hasHeaderRow: Bool = true) {
        self.delimiter = delimiter
        self.hasHeaderRow = hasHeaderRow
    }
}

struct TransactionCSVImportPreparationRequest: Sendable {
    let budgetID: String
    let accountID: String
    let data: Data
    var options: TransactionCSVImportOptions
}

/// One parsed row with the outcome the shared import reconcile decided for it
/// (the same rules and matching Bank Sync uses; main-to-dev D4).
struct TransactionCSVImportReviewRow: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Unmatched; inserted. The candidate is the row after rules, and
        /// `isTransfer` is true when it resolved to a transfer payee, the only
        /// way a CSV row becomes a transfer.
        case insert(BankSyncReconciliation.Candidate, isTransfer: Bool)
        /// Matched; the update fills the stored row, and `existing` is the
        /// stored row as reviewed, which apply re-checks inside the commit.
        case update(BankSyncReconciliation.MatchedUpdate, existing: BankSyncReconciliation.Existing)
        /// Matched, and nothing would change (a duplicate).
        case unchanged
        /// Matched a reconciled row; it is locked, so nothing is written.
        case reconciled
        /// A delete-transaction rule drops the row.
        case skippedByRule

        enum Kind: Equatable, Sendable {
            case insert, update, unchanged, reconciled, skippedByRule
        }

        var kind: Kind {
            switch self {
            case .insert: .insert
            case .update: .update
            case .unchanged: .unchanged
            case .reconciled: .reconciled
            case .skippedByRule: .skippedByRule
            }
        }

        /// Only inserts and updates write anything.
        var writes: Bool {
            switch self {
            case .insert, .update: true
            case .unchanged, .reconciled, .skippedByRule: false
            }
        }
    }

    let row: TransactionCSVImportRow
    let outcome: Outcome

    var id: String { row.id }
}

struct TransactionCSVImportReview: Equatable, Sendable {
    let rows: [TransactionCSVImportReviewRow]
    /// Store session the review was matched against. Apply rejects a review
    /// from an earlier session.
    let sessionGeneration: Int
}

/// Already-decided rows for the apply step. Rows the reviewer excluded are
/// simply absent; rows whose outcome writes nothing carry no write.
struct TransactionCSVImportApplyRequest: Sendable {
    let budgetID: String
    let accountID: String
    let sessionGeneration: Int
    let rows: [TransactionCSVImportReviewRow]
}

struct TransactionCSVImportApplyResult: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
}

@MainActor
protocol TransactionCSVImportRepositoryProtocol: AnyObject {
    /// Parses and validates the whole file (all-or-nothing), then matches it
    /// against the account's existing rows for review. Writes nothing.
    func prepareTransactionCSVImport(
        _ request: TransactionCSVImportPreparationRequest
    ) async throws -> TransactionCSVImportReview

    /// Applies the decided rows in one local commit; any failure writes zero
    /// rows.
    func applyTransactionCSVImport(
        _ request: TransactionCSVImportApplyRequest
    ) async throws -> TransactionCSVImportApplyResult
}
