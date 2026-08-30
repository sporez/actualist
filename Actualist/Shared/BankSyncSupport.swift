import Foundation

/// One authoritative gate for mutations owned by the SimpleFIN Bank Sync
/// surface. Other Actual-supported provider links remain visible but read-only.
enum BankSyncLinkEligibility {
    static let simpleFINSource = "simpleFin"

    static func isSimpleFIN(syncSource: String?) -> Bool {
        syncSource == simpleFINSource
    }
}

/// Durable `accounts.bank_sync_status` vocabulary that the local database and
/// the Accounts status dot already understand. Unknown codes render as
/// failures, matching `ActualAccount.bankSyncState`.
enum ActualBankSyncDurableStatus: String, Sendable {
    case ok
    case attentionRequired = "attention-required"
    case reauthRequired = "reauth-required"
    case rateLimitExceeded = "rate-limit-exceeded"
    case timedOut = "timed-out"
    case accountMissing = "account-missing"
    case failed

    /// Maps a download's error code onto the durable vocabulary. A nil code
    /// is a successful download. Codes come from the server's bank-sync
    /// error envelope (`TIMED_OUT`, `ACCOUNT_MISSING`,
    /// `RATE_LIMIT_EXCEEDED`, auth failures, provider-specific codes).
    static func from(errorCode: String?) -> ActualBankSyncDurableStatus {
        guard let errorCode else {
            return .ok
        }
        switch errorCode.uppercased() {
        case "TIMED_OUT":
            return .timedOut
        case "ACCOUNT_MISSING":
            return .accountMissing
        case "ACCOUNT_NEEDS_ATTENTION":
            return .attentionRequired
        case "RATE_LIMIT_EXCEEDED":
            return .rateLimitExceeded
        case "INVALID_ACCESS_TOKEN", "UNAUTHORIZED", "INVALID_CREDENTIALS":
            return .reauthRequired
        default:
            return .failed
        }
    }
}

/// Currency-safe conversions for bank-sync downloads. Amount scaling always
/// goes through the budget's `BudgetCurrency` scale — never `* 100`.
enum BankSyncAmounts {
    /// Canonical ISO-style code when the provider supplied one. Missing
    /// currency remains unknown for compatibility; an explicit mismatch is
    /// handled as a blocking normalization problem by the planner.
    static func normalizedCurrencyCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.isEmpty ? nil : code
    }

    /// Parses a raw decimal string from the SimpleFIN bridge into integer
    /// minor units using the budget currency's scale. Returns `nil` for junk
    /// rather than guessing: only an optional sign, digits, and at most one
    /// `.` separator are accepted.
    static func minorUnits(fromDecimal raw: String?, currency: BudgetCurrency) -> Int? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }

        var body = Substring(trimmed)
        var sign = 1
        if body.first == "-" {
            sign = -1
            body = body.dropFirst()
        } else if body.first == "+" {
            body = body.dropFirst()
        }

        guard !body.isEmpty else {
            return nil
        }

        var seenSeparator = false
        for character in body {
            if character == "." {
                if seenSeparator {
                    return nil
                }
                seenSeparator = true
            } else if !character.isNumber {
                return nil
            }
        }
        // Require at least one digit, and reject a leading lone separator
        // (".50") so junk is never guessed into an amount.
        guard body.contains(where: \.isNumber), body.first != "." else {
            return nil
        }

        guard let decimal = Decimal(string: String(body), locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        guard let minorUnits = currency.minorUnits(fromDisplay: decimal) else {
            return nil
        }
        return sign * minorUnits
    }

    /// UTC calendar day (`YYYYMMDD`) from UNIX seconds, matching the server's
    /// `toISOString().split('T')[0]` interpretation of bridge timestamps.
    static func dayID(fromUnixSeconds seconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Inverse of `dayID(fromUnixSeconds:)` for drafts: UTC noon on the given
    /// calendar day, so a normalized day survives Date round-trips.
    static func date(fromDayID dayID: String) -> Date? {
        let characters = Array(dayID)
        guard characters.count == 8, characters.allSatisfy(\.isNumber) else {
            return nil
        }
        var components = DateComponents()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = Int(dayID.prefix(4))
        components.month = Int(dayID.dropFirst(4).prefix(2))
        components.day = Int(dayID.suffix(2))
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: components)
    }

    /// Sync lookback start in `YYYY-MM-DD`: `max(today − 89 days, oldest live
    /// transaction date)` — the full 90-day window for an empty account
    /// (loot-core `getAccountSyncStartDate`).
    static func lookbackStartDate(oldestLiveTransactionDayID: String?, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let earliestAllowed = calendar.date(byAdding: .day, value: -89, to: now) ?? now
        var earliest = earliestAllowed
        if let oldestLiveTransactionDayID,
           let oldest = date(fromDayID: oldestLiveTransactionDayID),
           oldest > earliestAllowed {
            earliest = oldest
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: earliest)
    }
}
