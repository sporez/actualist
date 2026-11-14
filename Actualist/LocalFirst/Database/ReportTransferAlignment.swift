import Foundation

/// One day's summed amount over the accounts a net worth read counts.
struct RawNetWorthDay: Sendable, Equatable {
    let dayID: String
    let amount: Int
}

/// A live transaction row that carries a transfer link, in a counted account.
struct ReportTransferLeg: Sendable, Equatable {
    let id: String
    let transferID: String
    let accountID: String
    let amount: Int
    let dayID: String
}

/// Port of `alignInternalTransferDates` / `moveTransferLeg` (net-worth-spreadsheet.ts).
/// Both net worth reads call it, so a transfer between two counted accounts never
/// changes the total between its two posting dates.
enum ReportTransferAlignment {
    /// Moves the earlier leg of each qualifying pair onto the later leg's day.
    ///
    /// A pair qualifies when each leg's `transferID` is the other's id, the accounts
    /// differ, the amounts cancel and both legs were read (so both accounts are counted).
    /// A leg dated after `endDay` is not in `days`, so it is skipped; a later leg after
    /// `endDay` only removes the earlier amount. Days that existed stay in the result even
    /// when the move leaves them at zero, so callers that test for earlier activity do not
    /// change their answer. Whether the earlier day is before the report's start does not
    /// matter here: the opening balance sums every day before the start.
    static func align(
        _ days: [RawNetWorthDay],
        legs: [ReportTransferLeg],
        through endDay: String
    ) throws -> [RawNetWorthDay] {
        guard !legs.isEmpty else { return days }
        var amounts = Dictionary(days.map { ($0.dayID, $0.amount) }, uniquingKeysWith: { first, _ in first })
        let legsByID = Dictionary(legs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var processed = Set<String>()
        for leg in legs where !processed.contains(leg.id) {
            guard let counterpart = legsByID[leg.transferID],
                  counterpart.transferID == leg.id,
                  counterpart.accountID != leg.accountID,
                  try ReportArithmetic.add(counterpart.amount, leg.amount) == 0 else {
                continue
            }
            processed.insert(leg.id)
            processed.insert(counterpart.id)
            guard leg.dayID != counterpart.dayID else { continue }
            let (earlier, later) = leg.dayID < counterpart.dayID ? (leg, counterpart) : (counterpart, leg)
            guard earlier.dayID <= endDay, let original = amounts[earlier.dayID] else { continue }
            amounts[earlier.dayID] = try ReportArithmetic.subtract(original, earlier.amount)
            guard later.dayID <= endDay else { continue }
            amounts[later.dayID] = try ReportArithmetic.add(amounts[later.dayID] ?? 0, earlier.amount)
        }
        return amounts.keys.sorted().map { RawNetWorthDay(dayID: $0, amount: amounts[$0] ?? 0) }
    }
}
