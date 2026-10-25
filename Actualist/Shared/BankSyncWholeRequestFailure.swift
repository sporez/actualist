import Foundation

/// Why a whole `/simplefin/transactions` request failed, classified from the
/// server's error code. The server's `reason` text is untrusted and is never
/// decoded, stored or shown; Actual sends one fixed reason per code, so the
/// copy here is derived from the code alone.
enum BankSyncWholeRequestFailure: String, Equatable, Sendable, CaseIterable {
    case serverDown = "server-down"
    case accessRejected = "access-rejected"
    case timedOut = "timed-out"
    case rateLimited = "rate-limited"
    case other

    /// Nil when the code is absent: the request itself did not fail.
    static func classify(errorCode: String?) -> Self? {
        guard let errorCode else {
            return nil
        }
        switch errorCode.uppercased() {
        case "SERVER_DOWN":
            return .serverDown
        case "INVALID_ACCESS_TOKEN", "UNAUTHORIZED", "INVALID_CREDENTIALS":
            return .accessRejected
        case "TIMED_OUT":
            return .timedOut
        case "RATE_LIMIT_EXCEEDED":
            return .rateLimited
        default:
            return .other
        }
    }

    /// The run result shown on the Bank Sync screen and stored as the last run.
    var summary: String {
        switch self {
        case .serverDown:
            "Bank Sync could not run. Your Actual server could not reach SimpleFIN. Try again later."
        case .accessRejected:
            "Bank Sync could not run. SimpleFIN no longer accepts the saved access. Set up SimpleFIN again, then relink your accounts."
        case .timedOut:
            "Bank Sync could not run. SimpleFIN took too long to answer. Try again later."
        case .rateLimited:
            "Bank Sync could not run. SimpleFIN is limiting requests. Try again later."
        case .other:
            "Bank Sync failed on your Actual server. Try again later."
        }
    }
}
