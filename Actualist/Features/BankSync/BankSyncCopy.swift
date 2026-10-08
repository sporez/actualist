import Foundation

/// Shared copy for the Bank Sync screen. Kept out of the views so the
/// decision-log wording (server-shared connection, never a token) lives in
/// one place.
enum BankSyncCopy {
    static func lastSyncText(epochMilliseconds: Int64?, isLinked: Bool) -> String {
        guard isLinked else {
            return "Not linked"
        }
        guard let epochMilliseconds else {
            return "Never synced"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1_000)
        return "Synced " + CompactAgeText.text(since: date, now: Date())
    }

    static func statusText(durableStatus: String?) -> String? {
        guard let durableStatus, durableStatus != "ok" else {
            return nil
        }
        switch durableStatus {
        case "attention-required":
            return "Needs attention"
        case "reauth-required":
            return "Reconnect required"
        case "rate-limit-exceeded":
            return "Rate limited"
        case "timed-out":
            return "Timed out"
        case "account-missing":
            return "Account missing at bank"
        default:
            return "Failed"
        }
    }

    static func statusColorKind(durableStatus: String?, isLinked: Bool) -> BankSyncViewModel.AccountLine.StatusColorKind {
        guard isLinked else {
            return .none
        }
        switch durableStatus {
        case nil, "ok":
            return .healthy
        case "pending", "sync-requested":
            return .pending
        default:
            return .failed
        }
    }

    static func providerText(support: SimpleFINServerSupport?, hasDeviceKey: Bool, isDemoMode: Bool) -> String {
        if isDemoMode {
            return "Unavailable in demo mode"
        }
        switch support {
        case .configured:
            return "SimpleFIN via your server"
        case .notConfigured, .unsupported, nil:
            return hasDeviceKey ? "SimpleFIN via a device token" : "Not connected"
        }
    }

    static func connectionFooter(support: SimpleFINServerSupport?, hasDeviceKey: Bool, isDemoMode: Bool) -> String? {
        if isDemoMode {
            return "Demo budgets never contact a server, so bank sync is unavailable."
        }
        switch support {
        case .configured:
            return "This app and the Actual web UI share the same server connection."
        case .notConfigured:
            if hasDeviceKey {
                return deviceTokenFooter
            }
            return "Your server has no SimpleFIN setup token yet. Add one on the server, or connect with a SimpleFIN setup token below."
        case .unsupported, nil:
            if hasDeviceKey {
                return deviceTokenFooter
            }
            return "Your Actual server does not host the SimpleFIN routes. Connect with a SimpleFIN setup token below instead."
        }
    }

    static let deviceTokenFooter = "Connected with a SimpleFIN setup token on this device. The Actual web UI cannot refresh these links, because the access key is only stored here."

    static func dayText(_ dayID: String) -> String {
        guard dayID.count == 8 else {
            return dayID
        }
        let iso = "\(dayID.prefix(4))-\(dayID.dropFirst(4).prefix(2))-\(dayID.suffix(2))"
        return ActualDateDisplay.mediumDay(iso) ?? iso
    }

    static func matchChangeText(_ change: BankSyncReview.MatchChange) -> String {
        switch change.field {
        case .bankIDAttached:
            return "Attach bank transaction ID"
        case .bankIDReplaced:
            return "Replace existing bank transaction ID"
        case .payee:
            return "Payee: \(value(change.oldValue, empty: "None")) → \(value(change.newValue, empty: "None"))"
        case .category:
            return "Category: \(value(change.oldValue, empty: "Uncategorized")) → \(value(change.newValue, empty: "Uncategorized"))"
        case .bankPayee:
            return "Bank payee: \(quoted(change.oldValue)) → \(quoted(change.newValue))"
        case .notes:
            return "Notes: \(quoted(change.oldValue)) → \(quoted(change.newValue))"
        case .cleared:
            return "Cleared: \(boolText(change.oldValue)) → \(boolText(change.newValue))"
        case .splitChildrenCleared:
            let count = Int(change.newValue ?? "") ?? 0
            return count == 1
                ? "Mark 1 split transaction cleared"
                : "Mark \(count) split transactions cleared"
        }
    }

    private static func value(_ raw: String?, empty fallback: String) -> String {
        guard let raw, !raw.isEmpty else {
            return fallback
        }
        return raw
    }

    private static func quoted(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else {
            return "None"
        }
        return "“\(raw)”"
    }

    private static func boolText(_ raw: String?) -> String {
        raw == "true" ? "Yes" : "No"
    }

    static func problemSummary(_ problems: [BankSyncReview.Problem]) -> String? {
        guard !problems.isEmpty else {
            return nil
        }
        let counts = Dictionary(grouping: problems, by: \.message)
            .mapValues(\.count)
        return counts.keys.sorted().map { message in
            "\(counts[message] ?? 0)× \(message)"
        }.joined(separator: " · ")
    }

    static func backgroundSyncFooter(
        support: SimpleFINServerSupport?,
        phase: BankSyncViewModel.Phase,
        isDemoMode: Bool
    ) -> String {
        if isDemoMode {
            return "Unavailable in demo mode."
        }
        if phase == .idle || phase == .loading {
            return "Checking your server…"
        }
        guard support == .configured else {
            return "Requires SimpleFIN through your Actual server. Device-only tokens are not used for background sync."
        }
        return "After a background budget sync, linked bank accounts are downloaded and saved automatically. No notification is posted for this."
    }

    /// "Sync All · 2h ago" / "Background sync · just now".
    static func lastRunCaption(_ run: BankSyncLastRun, now: Date) -> String {
        let source = run.trigger == .background ? "Background sync" : "Sync All"
        return "\(source) · \(CompactAgeText.text(since: run.finishedAt, now: now))"
    }

}
