import Foundation

/// Structured, privacy-safe facts about one background refresh. This records
/// counts and stage outcomes only; never persist transaction/account/budget data
/// or arbitrary error text here.
struct BackgroundRefreshDiagnosticDetails: Codable, Equatable, Sendable {
    enum RefreshOutcome: String, Codable, Equatable, Sendable {
        case running
        case succeeded
        case failed
        case timedOut
        case cancelled
        case skipped
    }

    enum BankOutcome: String, Codable, Equatable, Sendable {
        case running
        case succeeded
        case failed
        case timedOut
        case cancelled
        case skipped
    }

    enum NotificationOutcome: String, Codable, Equatable, Sendable {
        case notAttempted
        case attempted
        case accepted
        case failed
        case cancelled
    }

    var alertsEnabled: Bool
    var refreshOutcome: RefreshOutcome
    var serverInsertedCount: Int?
    var serverSyncDurationMilliseconds: Int?
    var bankOutcome: BankOutcome?
    var bankAccountCount: Int?
    var bankInsertedCount: Int?
    var bankDurationMilliseconds: Int?
    var notificationCandidateCount: Int?
    var durablePendingIDCount: Int?
    var notificationOutcome: NotificationOutcome

    init(alertsEnabled: Bool) {
        self.alertsEnabled = alertsEnabled
        self.refreshOutcome = .running
        self.serverInsertedCount = nil
        self.serverSyncDurationMilliseconds = nil
        self.bankOutcome = nil
        self.bankAccountCount = nil
        self.bankInsertedCount = nil
        self.bankDurationMilliseconds = nil
        self.notificationCandidateCount = nil
        self.durablePendingIDCount = nil
        self.notificationOutcome = .notAttempted
    }
}

/// The shared presentation contract for Developer diagnostics and report
/// export. Typed details are authoritative; historic message strings are
/// intentionally excluded from this projection.
enum BackgroundRefreshDiagnosticProjection {
    static func lines(_ details: BackgroundRefreshDiagnosticDetails) -> [String] {
        var result = ["Alerts enabled: \(yesNo(details.alertsEnabled))"]
        result.append("Refresh: \(details.refreshOutcome.rawValue)")
        if let count = details.serverInsertedCount {
            result.append("Server new transactions: \(count)")
        }
        if let duration = details.serverSyncDurationMilliseconds {
            result.append("Server sync time: \(duration) ms")
        }
        if let outcome = details.bankOutcome {
            result.append("Bank sync: \(outcome.rawValue)")
        }
        if let count = details.bankAccountCount {
            result.append("Bank accounts: \(count)")
        }
        if let count = details.bankInsertedCount {
            result.append("Bank new transactions: \(count)")
        }
        if let duration = details.bankDurationMilliseconds {
            result.append("Bank sync time: \(duration) ms")
        }
        if let count = details.notificationCandidateCount {
            result.append("Notification candidates: \(count)")
        }
        if let count = details.durablePendingIDCount {
            result.append("Pending IDs recorded for budget: \(count)")
        }
        result.append("Notification request: \(details.notificationOutcome.rawValue)")
        return result
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
