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

/// One parsed row with its already-decided reconcile disposition.
struct TransactionCSVImportReviewRow: Identifiable, Equatable, Sendable {
    let row: TransactionCSVImportRow
    let disposition: TransactionCSVImportDisposition

    var id: String { row.id }
}

struct TransactionCSVImportReview: Equatable, Sendable {
    let rows: [TransactionCSVImportReviewRow]
}

/// Already-decided rows for the apply step. Rows the reviewer excluded are
/// simply absent; ignored and reconciled-skip rows carry no write.
struct TransactionCSVImportApplyRequest: Sendable {
    let budgetID: String
    let accountID: String
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
