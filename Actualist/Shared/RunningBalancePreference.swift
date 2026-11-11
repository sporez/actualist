import Foundation

/// Where Actual keeps an account's running-balance setting, and how to read
/// and change it. Actual 26.11's desktop table stores column visibility in
/// `transaction-table-columns-<accountId>` (else the budget-wide
/// `transaction-table-columns`) and reads the older `show-balances-<accountId>`
/// only when neither is set (`useTransactionTableColumns`). Actual's mobile web
/// reads `show-balances-<accountId>` alone (`AccountTransactions.tsx`).
enum RunningBalancePreference {
    struct Values: Equatable, Sendable {
        /// `transaction-table-columns-<accountId>`.
        var viewColumns: String?
        /// `transaction-table-columns`.
        var globalColumns: String?
        /// `show-balances-<accountId>`.
        var showBalances: String?
    }

    struct Column: Equatable, Sendable {
        let id: String
        var hidden: Bool
    }

    static func keys(accountID: String) -> [SyncedPreferenceKey] {
        [.transactionTableColumns(accountID: accountID), .transactionTableColumns, .showBalances(accountID: accountID)]
    }

    static func values(_ stored: [String: String], accountID: String) -> Values {
        Values(
            viewColumns: stored[SyncedPreferenceKey.transactionTableColumns(accountID: accountID).id],
            globalColumns: stored[SyncedPreferenceKey.transactionTableColumns.id],
            showBalances: stored[SyncedPreferenceKey.showBalances(accountID: accountID).id]
        )
    }

    /// Desktop's `showBalances`: a saved layout decides when one exists (an
    /// empty string counts as unset, as JavaScript's `||` treats it).
    static func isShown(_ values: Values) -> Bool {
        if let layout = savedLayout(values) {
            return parseColumns(layout).first { $0.id == "balance" }?.hidden == false
        }
        return values.showBalances == "true"
    }

    /// The writes that make every Actual client agree on `enabled`.
    /// `show-balances-<id>` always changes (mobile web and desktop's fallback).
    /// When a layout is saved, this account's layout changes too; a budget-wide
    /// layout is copied into this account's key, as desktop's per-view save does.
    static func writes(
        enabled: Bool,
        accountID: String,
        current values: Values
    ) -> [(key: SyncedPreferenceKey, value: String)] {
        var writes: [(key: SyncedPreferenceKey, value: String)] = [
            (.showBalances(accountID: accountID), enabled ? "true" : "false"),
        ]
        if let layout = savedLayout(values) {
            let columns = parseColumns(layout).map { column in
                column.id == "balance" ? Column(id: column.id, hidden: !enabled) : column
            }
            writes.append((.transactionTableColumns(accountID: accountID), serialize(columns)))
        }
        return writes
    }

    /// Port of Actual's `parseTransactionTableColumns`
    /// (`desktop-client/src/components/transactions/table/columns.ts`).
    static func parseColumns(_ raw: String?) -> [Column] {
        var saved: [Column] = []
        if let raw, !raw.isEmpty, case .array(let entries)? = JavaScriptJSONValue.parse(raw) {
            for entry in entries {
                guard case .object(let fields) = entry,
                      case .string(let id)? = fields["id"],
                      columnIDs.contains(id),
                      !saved.contains(where: { $0.id == id }) else { continue }
                let hidden = fields["hidden"] == .bool(true) && id != "date"
                saved.append(Column(id: id, hidden: hidden))
            }
        }
        if let payment = saved.firstIndex(where: { $0.id == "payment" }),
           let deposit = saved.firstIndex(where: { $0.id == "deposit" }),
           saved[payment].hidden, saved[deposit].hidden {
            saved[payment].hidden = false
            saved[deposit].hidden = false
        }
        for (defaultIndex, id) in columnIDs.enumerated() where !saved.contains(where: { $0.id == id }) {
            let column = Column(id: id, hidden: hiddenByDefault.contains(id))
            if let insertAt = saved.firstIndex(where: { (columnIDs.firstIndex(of: $0.id) ?? 0) > defaultIndex }) {
                saved.insert(column, at: insertAt)
            } else {
                saved.append(column)
            }
        }
        return saved
    }

    /// `JSON.stringify` of the column list; ids are fixed ASCII names.
    static func serialize(_ columns: [Column]) -> String {
        "[" + columns.map { "{\"id\":\"\($0.id)\",\"hidden\":\($0.hidden)}" }.joined(separator: ",") + "]"
    }

    private static let columnIDs = [
        "date", "account", "payee", "notes", "group", "category", "payment", "deposit", "balance", "cleared",
    ]
    private static let hiddenByDefault: Set<String> = ["balance", "group"]

    private static func savedLayout(_ values: Values) -> String? {
        if let view = values.viewColumns, !view.isEmpty { return view }
        if let global = values.globalColumns, !global.isEmpty { return global }
        return nil
    }
}
