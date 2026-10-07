import Foundation

/// The rule step every import shares: build the draft the rules evaluate,
/// then project each candidate through its rule preview before matching
/// (loot-core runs `runRules` on `transactionsStep1`, ahead of any match).
/// Pure; the caller owns the batched `previewRules` call.
enum ImportReconcileProjection {
    /// Rules evaluate imported calendar days in UTC, as Bank Sync always has.
    /// CSV days are ISO calendar days, so the same zone applies to them.
    static let ruleDateTimeZone = ActualDateOnly.utc

    struct Result: Equatable, Sendable {
        /// Candidates that survive their rules, in input order.
        var candidates: [BankSyncReconciliation.Candidate]
        /// The input index of each surviving candidate.
        var sources: [Int]
        /// Input indices whose rule moves the row to another account. An
        /// import never writes into an account other than its own, so the
        /// caller refuses them rather than dropping them silently.
        var movedSources: [Int]
    }

    /// The draft rules see. A new payee has no id yet, so the raw name rides
    /// along as `payeeName` and `importedPayee` (rules can match both).
    static func previewDraft(
        for candidate: BankSyncReconciliation.Candidate,
        accountID: String
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: accountID,
            date: BankSyncAmounts.date(fromDayID: candidate.dayID) ?? Date(timeIntervalSince1970: 0),
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: candidate.payeeID,
            payeeName: candidate.payeeName ?? "",
            categoryID: candidate.categoryID,
            notes: candidate.notes,
            cleared: candidate.cleared,
            isTransfer: false,
            importedPayee: candidate.importedPayee
        )
    }

    /// `previews` holds one preview per candidate, in order.
    static func project(
        candidates: [BankSyncReconciliation.Candidate],
        previews: [TransactionRulePreview],
        accountID: String,
        accountIsOffBudget: Bool
    ) -> Result {
        var result = Result(candidates: [], sources: [], movedSources: [])
        result.candidates.reserveCapacity(candidates.count)
        for (source, (candidate, preview)) in zip(candidates, previews).enumerated() {
            if let destination = preview.accountID, destination != accountID {
                result.movedSources.append(source)
                continue
            }
            if let projected = BankSyncReconciliation.applyingRulePreview(
                preview,
                to: candidate,
                accountIsOffBudget: accountIsOffBudget
            ) {
                result.candidates.append(projected)
                result.sources.append(source)
            }
        }
        return result
    }
}
