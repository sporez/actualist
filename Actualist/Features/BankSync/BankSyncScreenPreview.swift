#if DEBUG
import Foundation

/// Screenshot seam for the Bank Sync screen. DEBUG builds launched with
/// `-actualist-bank-sync-preview` show the open budget's own accounts in a
/// mixed SimpleFIN and Enable Banking state, without asking a server: the
/// bundled demo budget has no linked accounts and never contacts one. Account
/// lines still go through the production copy; nothing is written.
struct BankSyncScreenPreview {
    static let launchFlag = "-actualist-bank-sync-preview"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }

    let rows: [BankSyncWorkflows.BankSyncAccountStatusRow]
    let lastRun: BankSyncLastRun
    let resultLines: [BankSyncViewModel.ResultLine]

    /// The first open account syncs through SimpleFIN, the next two through
    /// Enable Banking (one needs reconnecting in the Actual web app).
    init(accounts: [BankSyncWorkflows.BankSyncAccountStatusRow], now: Date = Date()) {
        let synced = Int64((now.timeIntervalSince1970 - 2 * 3_600) * 1_000)
        let links: [(source: String, status: String)] = [
            (BankSyncLinkEligibility.simpleFINSource, "ok"),
            (BankSyncLinkEligibility.enableBankingSource, "ok"),
            (BankSyncLinkEligibility.enableBankingSource, ActualBankSyncDurableStatus.reauthRequired.rawValue),
        ]
        rows = accounts.enumerated().map { index, account in
            guard index < links.count else { return account }
            return BankSyncWorkflows.BankSyncAccountStatusRow(
                id: account.id,
                name: account.name,
                isLinked: true,
                syncSource: links[index].source,
                remoteAccountID: "preview-\(index)",
                lastSyncEpochMilliseconds: synced,
                durableStatus: links[index].status
            )
        }
        lastRun = BankSyncLastRun(
            finishedAt: now.addingTimeInterval(-5 * 60),
            trigger: .manual,
            summary: "Synced 2 of 3 accounts. Added 4 transactions · Updated 1 match · 1 account skipped"
        )
        let names = rows.prefix(links.count).map(\.name)
        resultLines = names.enumerated().map { index, name in
            BankSyncViewModel.ResultLine(
                id: "preview-result-\(index)",
                accountName: name,
                addedCount: index == 2 ? 0 : 2,
                updatedCount: index == 1 ? 1 : 0,
                matchLines: [],
                unchangedCount: index == 2 ? 0 : 3,
                problemCount: 0,
                problemSummary: nil,
                statusText: index == 2
                    ? "Skipped · \(BankSyncCopy.statusText(durableStatus: links[2].status, provider: .enableBanking) ?? "Failed")"
                    : nil,
                openingBalanceText: nil
            )
        }
    }
}
#endif
