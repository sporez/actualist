import Foundation

/// What the Diagnostic Report says about Bank Sync: each linked account's
/// durable status and last sync time, and the last run's outcome. It holds no
/// account names, IDs, institutions, amounts or server text.
struct BankSyncDiagnosticSnapshot: Equatable, Sendable {
    struct Account: Equatable, Sendable {
        let status: String
        let lastSync: Date?

        /// Only a value from the durable vocabulary is kept; anything else is
        /// "unrecognized" so synced text cannot reach the report.
        init(status raw: String?, lastSync: Date?) {
            if let raw {
                let known = ActualBankSyncDurableStatus(rawValue: raw) != nil
                    || raw == "pending" || raw == "sync-requested"
                status = known ? raw : "unrecognized"
            } else {
                status = ActualBankSyncDurableStatus.ok.rawValue
            }
            self.lastSync = lastSync
        }
    }

    let accounts: [Account]
    let lastRun: BankSyncLastRun?

    static func load(from database: BudgetDatabase) async -> BankSyncDiagnosticSnapshot? {
        guard let linked = try? await database.bankSyncLinkedAccounts() else {
            return nil
        }
        let lastRun = try? await database.bankSyncLastRun()
        return BankSyncDiagnosticSnapshot(
            accounts: linked.map { account in
                Account(
                    status: account.bankSyncStatus,
                    lastSync: account.lastSync
                        .flatMap { Int64($0) }
                        .map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
                )
            },
            lastRun: lastRun
        )
    }
}

extension LocalFirstActualStore {
    /// Nil when no budget is open or its Bank Sync data cannot be read.
    func bankSyncDiagnosticSnapshot() async -> BankSyncDiagnosticSnapshot? {
        guard let database else {
            return nil
        }
        return await BankSyncDiagnosticSnapshot.load(from: database)
    }
}
