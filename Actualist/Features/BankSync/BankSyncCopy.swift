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

    /// A generic failure left by a whole-request failure reads "Not synced":
    /// the cause is shown once in the last result, not on every account.
    /// Enable Banking consent is renewed only in the Actual web app.
    static func statusText(
        durableStatus: String?,
        lastRunFailure: BankSyncWholeRequestFailure? = nil,
        provider: BankSyncProviderKind? = nil
    ) -> String? {
        guard let durableStatus, durableStatus != "ok" else {
            return nil
        }
        if durableStatus == "failed", lastRunFailure != nil {
            return "Not synced"
        }
        switch durableStatus {
        case "attention-required":
            return "Needs attention"
        case "reauth-required":
            return provider == .enableBanking ? "Reconnect in Actual web app" : "Reconnect required"
        case "not-configured":
            return "Not set up on server"
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

    /// The sheet footer of a linked account.
    static func linkedFooter(provider: BankSyncProviderKind?, durableStatus: String?) -> String {
        switch provider {
        case .simpleFIN:
            return "Unlinking keeps this account’s transactions. Only the bank connection is removed."
        case .enableBanking:
            if durableStatus == ActualBankSyncDurableStatus.reauthRequired.rawValue {
                return "Your bank needs you to sign in again. Reconnect this account in the Actual web app, then sync here."
            }
            return "This account syncs through Enable Banking. Link, reconnect or unlink it in the Actual web app."
        case nil:
            return "This account is linked through another bank provider. Unlink it in the Actual web app first."
        }
    }

    /// Why the link sheet lists no SimpleFIN accounts. Enable Banking links
    /// are made in the Actual web app.
    static func linkUnavailableText(enableBanking: SimpleFINServerSupport?) -> String {
        let simpleFIN = "Bank accounts cannot be linked because your server is not set up for SimpleFIN."
        guard enableBanking == .configured else { return simpleFIN }
        return simpleFIN + " To link this account to Enable Banking, use the Actual web app."
    }

    static func providerText(
        support: SimpleFINServerSupport?,
        hasDeviceKey: Bool,
        enableBanking: SimpleFINServerSupport? = nil,
        isDemoMode: Bool
    ) -> String {
        if isDemoMode {
            return "Unavailable in demo mode"
        }
        let enableBankingOnServer = enableBanking == .configured
        switch support {
        case .configured:
            return enableBankingOnServer ? "SimpleFIN and Enable Banking" : "SimpleFIN via your server"
        case .notConfigured, .unsupported, nil:
            switch (hasDeviceKey, enableBankingOnServer) {
            case (true, true): return "SimpleFIN on this device · Enable Banking via your server"
            case (true, false): return "SimpleFIN on this device"
            case (false, true): return "Enable Banking via your server"
            case (false, false): return "Not connected"
            }
        }
    }

    static func connectionFooter(
        support: SimpleFINServerSupport?,
        hasDeviceKey: Bool,
        enableBanking: SimpleFINServerSupport? = nil,
        showsSimpleFINToken: Bool = true,
        isDemoMode: Bool
    ) -> String? {
        if isDemoMode {
            return "Demo budgets never contact a server, so Bank Sync is unavailable."
        }
        if enableBanking == .configured, support == .configured || !showsSimpleFINToken {
            return "This app and the Actual web app share the same server connection. Link Enable Banking accounts in the Actual web app."
        }
        switch support {
        case .configured:
            return "This app and the Actual web app share the same server connection."
        case .notConfigured:
            if hasDeviceKey {
                return deviceTokenFooter
            }
            return "Your server is not set up for SimpleFIN. Set it up on the server, or paste a setup token below."
        case .unsupported, nil:
            if hasDeviceKey {
                return deviceTokenFooter
            }
            return "Your Actual server does not support SimpleFIN. Paste a setup token below instead."
        }
    }

    static let deviceTokenFooter = "Connected on this device only. The Actual web app cannot refresh these links."

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
            return "Link to bank import"
        case .bankIDReplaced:
            return "Replace earlier bank import"
        case .payee:
            return "Payee: \(value(change.oldValue, empty: "None")) → \(value(change.newValue, empty: "None"))"
        case .newPayee:
            return "Payee: None → \(value(change.newValue, empty: "None")) (new payee)"
        case .date:
            return "Date: \(dayText(change.oldValue ?? "")) → \(dayText(change.newValue ?? ""))"
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
        enableBanking: SimpleFINServerSupport? = nil,
        phase: BankSyncViewModel.Phase,
        isDemoMode: Bool
    ) -> String {
        if isDemoMode {
            return "Unavailable in demo mode."
        }
        if phase == .idle || phase == .loading {
            return "Checking your server…"
        }
        guard support == .configured || enableBanking == .configured else {
            return "Works only when SimpleFIN or Enable Banking is set up on your Actual server."
        }
        return "After a background sync, linked bank accounts download automatically. You will not get a notification."
    }

    /// "Sync All · 2h ago" / "Background sync · just now".
    static func lastRunCaption(_ run: BankSyncLastRun, now: Date) -> String {
        let source = run.trigger == .background ? "Background sync" : "Sync All"
        return "\(source) · \(CompactAgeText.text(since: run.finishedAt, now: now))"
    }

}
