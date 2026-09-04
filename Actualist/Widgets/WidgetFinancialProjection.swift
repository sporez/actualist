import Foundation

enum WidgetFinancialProjection {
    static func currentSnapshot(_ snapshot: WidgetSnapshot?, now: Date = Date()) -> WidgetSnapshot? {
        guard let snapshot, snapshot.month == WidgetMonthID.current(now: now) else { return nil }
        return snapshot
    }

    static func accounts(selectedIDs: [String], snapshot: WidgetSnapshot?, limit: Int, now: Date = Date()) -> [WidgetAccountSnapshot] {
        guard let snapshot = currentSnapshot(snapshot, now: now), let accounts = snapshot.accounts else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var seen = Set<String>()
        return Array(selectedIDs.filter { seen.insert($0).inserted }.compactMap { byID[$0] }.prefix(max(limit, 0)))
    }
}
