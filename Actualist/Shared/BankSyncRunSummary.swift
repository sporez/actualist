import Foundation

/// The most recent finished Bank Sync run on this device. Stored in the open
/// budget's local database so the Bank Sync screen can show it again later.
struct BankSyncLastRun: Equatable, Sendable {
    enum Trigger: String, Sendable {
        case manual
        case background
    }

    let finishedAt: Date
    let trigger: Trigger
    let summary: String
}

/// Running totals for one Bank Sync run. Sync All and background bank sync
/// share it so both record the same summary wording.
struct BankSyncRunTally: Equatable, Sendable {
    static let nothingSavedSummary = "Sync didn't finish. Nothing was saved."

    private(set) var completedCount = 0
    private(set) var skippedCount = 0
    private(set) var insertedCount = 0
    private(set) var updatedCount = 0
    private(set) var openingBalanceCount = 0

    /// Counts one committed account. A skipped account committed only its
    /// provider status.
    mutating func record(_ result: BankSyncReview.ApplyResult, skipped: Bool) {
        insertedCount += result.insertedCount
        updatedCount += result.updatedCount
        openingBalanceCount += result.openingBalanceInserted ? 1 : 0
        completedCount += 1
        skippedCount += skipped ? 1 : 0
    }

    /// Summary after every planned account was applied.
    func completedSummary(plannedCount: Int) -> String {
        if skippedCount == plannedCount {
            return "No accounts synced. \(skippedCount) skipped."
        }
        return (skippedCount > 0 ? "Synced \(completedCount - skippedCount) of \(plannedCount) accounts. " : "")
            + changesText
            + skippedSuffix
    }

    /// Summary for a run that stopped early; nil when no account committed.
    func stoppedSummary(totalCount: Int) -> String? {
        guard completedCount > 0 else {
            return nil
        }
        return "Sync stopped after \(completedCount) of \(totalCount) accounts. "
            + (completedCount == skippedCount ? "No transactions imported." : changesText)
            + skippedSuffix
    }

    private var changesText: String {
        var parts: [String] = []
        if insertedCount > 0 {
            parts.append(insertedCount == 1 ? "Added 1 transaction" : "Added \(insertedCount) transactions")
        }
        if updatedCount > 0 {
            parts.append(updatedCount == 1 ? "Updated 1 match" : "Updated \(updatedCount) matches")
        }
        if openingBalanceCount > 0 {
            parts.append(openingBalanceCount == 1
                ? "Added 1 opening balance"
                : "Added \(openingBalanceCount) opening balances")
        }
        return parts.isEmpty ? "Everything already matches." : parts.joined(separator: " · ")
    }

    private var skippedSuffix: String {
        switch skippedCount {
        case 0: ""
        case 1: " · 1 account skipped"
        default: " · \(skippedCount) accounts skipped"
        }
    }
}
