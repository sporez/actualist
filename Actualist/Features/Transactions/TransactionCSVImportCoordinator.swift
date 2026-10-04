import Foundation
import Observation

/// Owns the CSV import workflow state: file read, parse/match preparation,
/// per-row review inclusion, submission, and completion. Views call intents
/// and display state; no money math or payload decisions live in the view.
@MainActor
@Observable
final class TransactionCSVImportCoordinator {
    enum State: Equatable {
        case idle
        case loading
        case reviewing(TransactionCSVImportReview)
        case submitting(TransactionCSVImportReview)
        case completed(TransactionCSVImportApplyResult)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Rows the reviewer deselected. Ignored and reconciled-skip rows are
    /// fixed-excluded; new and update rows start included. Observed: the
    /// review list re-renders from it.
    private var excludedRowIDs: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedAccountID: String?
    @ObservationIgnored private var loadedBudgetID: String?

    @ObservationIgnored private let maxFileBytes: Int

    init(maxFileBytes: Int = TransactionCSVImportLimits.maxFileBytes) {
        self.maxFileBytes = maxFileBytes
    }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Import is not recorded in History and has no Undo yet (plan D5), so the
    /// review states it before the user commits.
    var reviewNotice: String? {
        guard case .reviewing = state else { return nil }
        return "Imported transactions can't be undone."
    }

    var isSubmitting: Bool {
        if case .submitting = state { return true }
        return false
    }

    var isPresenting: Bool {
        switch state {
        case .idle: return false
        case .loading, .reviewing, .submitting, .completed, .failed: return true
        }
    }

    func load(
        contentsOf url: URL,
        accountID: String,
        budgetID: String,
        repository: any TransactionCSVImportRepositoryProtocol
    ) async {
        guard canStartWorkflow else { return }
        generation &+= 1
        let loadGeneration = generation
        excludedRowIDs = []
        loadedAccountID = accountID
        loadedBudgetID = budgetID
        state = .loading
        do {
            // Off the main actor, with security-scoped access held for the
            // read. An oversized file throws before prepare is called.
            let data = try await TransactionCSVImportPipeline.readFile(at: url, maxBytes: maxFileBytes)
            let review = try await repository.prepareTransactionCSVImport(
                TransactionCSVImportPreparationRequest(
                    budgetID: budgetID,
                    accountID: accountID,
                    data: data,
                    options: TransactionCSVImportOptions()
                )
            )
            guard loadGeneration == generation, !Task.isCancelled else { return }
            state = .reviewing(review)
        } catch {
            guard loadGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            state = .failed(Self.failureMessage(for: error))
        }
    }

    func toggleIncluded(_ row: TransactionCSVImportReviewRow) {
        guard case .reviewing = state else { return }
        switch row.disposition {
        case .ignored, .skippedReconciled:
            return
        case .insert, .update:
            let id = row.id
            if excludedRowIDs.contains(id) {
                excludedRowIDs.remove(id)
            } else {
                excludedRowIDs.insert(id)
            }
        }
    }

    func isToggleable(_ row: TransactionCSVImportReviewRow) -> Bool {
        switch row.disposition {
        case .insert, .update: return true
        case .ignored, .skippedReconciled: return false
        }
    }

    func isIncluded(_ row: TransactionCSVImportReviewRow) -> Bool {
        switch row.disposition {
        case .ignored, .skippedReconciled:
            return false
        case .insert, .update:
            return !excludedRowIDs.contains(row.id)
        }
    }

    var summary: (insert: Int, update: Int, ignored: Int, skipped: Int)? {
        guard case .reviewing(let review) = state else { return nil }
        var summary = (insert: 0, update: 0, ignored: 0, skipped: 0)
        for row in review.rows {
            switch row.disposition {
            case .insert: summary.insert += 1
            case .update: summary.update += 1
            case .ignored: summary.ignored += 1
            case .skippedReconciled: summary.skipped += 1
            }
        }
        return summary
    }

    struct SummaryLine: Equatable, Identifiable {
        let title: String
        let count: Int
        let symbol: String
        var id: String { title }
    }

    /// Review summary rows in display order. Duplicates and rows that match a
    /// reconciled transaction are different outcomes, so they stay separate.
    var summaryLines: [SummaryLine] {
        guard let summary else { return [] }
        var lines = [
            SummaryLine(title: "New rows", count: summary.insert, symbol: "plus.square"),
            SummaryLine(title: "Existing rows updated", count: summary.update, symbol: "pencil.line"),
            SummaryLine(title: "Duplicates left unchanged", count: summary.ignored, symbol: "checkmark.circle")
        ]
        if summary.skipped > 0 {
            lines.append(SummaryLine(title: "Matches reconciled rows", count: summary.skipped, symbol: "lock.circle"))
        }
        return lines
    }

    var canSubmit: Bool {
        guard case .reviewing(let review) = state else { return false }
        return review.rows.contains { isIncluded($0) }
    }

    var submitTitle: String {
        guard case .reviewing(let review) = state else { return "Import" }
        let count = review.rows.filter { isIncluded($0) }.count
        return "Import \(count) Row\(count == 1 ? "" : "s")"
    }

    /// `onImported` runs once after a committed import, so the app can record
    /// the local data mutation for widgets, Accounts, Budget and Reports.
    func submit(
        repository: any TransactionCSVImportRepositoryProtocol,
        onImported: () -> Void = {}
    ) async {
        guard case .reviewing(let review) = state, canSubmit,
              let accountID = loadedAccountID, let budgetID = loadedBudgetID else {
            return
        }
        generation &+= 1
        let submitGeneration = generation
        let selections = review.rows.filter { isIncluded($0) }
        state = .submitting(review)
        do {
            let result = try await repository.applyTransactionCSVImport(
                TransactionCSVImportApplyRequest(
                    budgetID: budgetID,
                    accountID: accountID,
                    sessionGeneration: review.sessionGeneration,
                    rows: selections
                )
            )
            // The commit already happened, so record it even when the sheet
            // was dismissed while the apply was in flight.
            onImported()
            guard submitGeneration == generation, !Task.isCancelled else { return }
            state = .completed(result)
        } catch {
            guard submitGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            state = .failed(Self.failureMessage(for: error))
        }
    }

    func reset() {
        guard !isSubmitting else { return }
        generation &+= 1
        state = .idle
        excludedRowIDs = []
        loadedAccountID = nil
        loadedBudgetID = nil
    }

    private var canStartWorkflow: Bool {
        switch state {
        case .idle, .failed: return true
        case .loading, .reviewing, .submitting, .completed: return false
        }
    }

    private static func failureMessage(for error: Error) -> String {
        if let importError = error as? TransactionCSVImportError {
            var message = importError.message
            if case .invalidRow = importError {
                message += " Nothing was imported."
            }
            return message
        }
        return "The CSV could not be imported. Your budget has not been changed."
    }
}
