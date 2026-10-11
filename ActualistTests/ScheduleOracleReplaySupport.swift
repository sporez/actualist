import Foundation
@testable import Actualist

/// Replays the Schedules oracle contract through production schedule code. The recurrence and status families
/// are pure; the stateful family lives in `ScheduleStatefulReplay`. The compared and excluded fields are
/// documented in `scripts/schedule-parity/README.md` ("Swift replay").
enum ScheduleOracleFixture {
    static let domain = "Schedules"
    static let fileName = "schedules-contract.json"
    static let manifestName = "schedules-manifest.json"
    /// The fixture's `timeZone`. Production schedule code is zone-free (a GMT calendar and civil day strings),
    /// so the zone only matters for the `Date` values the replay injects as `now`.
    static let timeZone = TimeZone(identifier: "America/New_York")!

    static func cases() throws -> OracleFixtureCases {
        try OracleFixtureCases(domain: domain, fileName: fileName, outputKey: "queries")
    }

    static func manifest() throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        return try OracleJSON.object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), manifestName)
    }

    /// Local noon of `dayID` in the fixture zone, the `now` the replay injects.
    static func noon(_ dayID: String) throws -> Date {
        guard let date = ActualDateOnly.date(from: dayID, timeZone: timeZone) else {
            throw OracleReplayError.malformedFixture("bad day \(dayID)")
        }
        return date
    }
}

// MARK: Recurrence

/// Replays `getNextDate` (with and without weekend skipping) and `getNextDateAfter`.
///
/// The condition goes through `ScheduleRuleProjection.dateRule(from:)`, the decoder production applies to stored
/// rules. `getNextDate` is `ScheduleRuleMutation.initialNextDate`, which is what `createSchedule` and a date edit
/// call; without weekend skipping it is the same two primitives (`nextOccurrence`, then `lastOccurrence`) with the
/// adjustment off. `getNextDateAfter` is `ScheduleRuleMutation.nextDateAfterSkip`, what a user skip calls. Errors
/// are not compared by wording: an oracle error and a null result both mean "no date", and a production throw or
/// nil is the same.
enum ScheduleRecurrenceReplay {
    struct QueryResult {
        let label: String
        let expected: OracleValue
        let actual: OracleValue
        var mismatches: [ReplayMismatch] {
            var comparison = OracleComparison()
            comparison.compare(expected: expected, actual: actual, path: label)
            return comparison.mismatches
        }
    }

    static func replay(_ entry: [String: Any]) throws -> [QueryResult] {
        let conditionJSON = try OracleJSON.object(entry["condition"], "condition")
        let condition = try JSONDecoder().decode(
            RuleCondition.self,
            from: JSONSerialization.data(withJSONObject: conditionJSON)
        )
        let rule = ScheduleRuleProjection.dateRule(from: condition)
        let recurrence = rule.recurrence
        let skipsWeekend = (conditionJSON["value"] as? [String: Any])?["skipWeekend"] as? Bool == true

        var results: [QueryResult] = []
        for query in try OracleJSON.objects(entry["queries"], "queries") {
            let from = try OracleJSON.string(query, "from")
            func expectedDate(_ key: String) throws -> OracleValue {
                let outcome = try OracleJSON.object(query[key], key)
                if let value = outcome["value"] as? String { return .string(value) }
                return .null
            }
            func result(_ key: String, actual: String?) throws -> QueryResult {
                QueryResult(
                    label: "\(from).\(key)",
                    expected: try expectedDate(key),
                    actual: actual.map { .string($0) } ?? .null
                )
            }
            results.append(try result("nextDate", actual: nextDate(rule: rule, from: from, adjustingWeekend: true)))
            results.append(try result("nextDateNoSkipWeekend", actual: nextDate(rule: rule, from: from, adjustingWeekend: false)))
            // A one-time schedule cannot be skipped in production, so only recurrences compare the skip date. The
            // skip date starts from a schedule's current next date, which a weekend-skipping schedule never has on a
            // Saturday or Sunday, so those `from` days are not reachable inputs and are not compared.
            if let recurrence, !(skipsWeekend && isWeekend(from)) {
                let skipped = try? ScheduleRuleMutation.nextDateAfterSkip(recurrence: recurrence, currentDayID: from)
                results.append(try result("nextDateAfter", actual: skipped))
            }
        }
        return results
    }

    private static func isWeekend(_ dayID: String) -> Bool {
        guard let date = ActualScheduleRecurrence.date(from: dayID) else { return false }
        let weekday = Calendar.actualScheduleGregorian.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    private static func nextDate(rule: ScheduleDateRule, from: String, adjustingWeekend: Bool) -> String? {
        switch rule {
        case .oneTime(let dayID, _):
            return dayID
        case .unavailable:
            return nil
        case .recurring(let recurrence, _):
            if adjustingWeekend {
                return try? ScheduleRuleMutation.initialNextDate(for: rule, asOf: from)
            }
            if let next = try? recurrence.nextOccurrence(onOrAfter: from, applyWeekendAdjustment: false) {
                return next
            }
            return try? recurrence.lastOccurrence(applyWeekendAdjustment: false)
        }
    }
}

// MARK: Status

/// Replays `getStatus` and `getUpcomingDays` through `ScheduleStatus.resolve` and `ScheduleUpcomingLength.days`.
/// These are exactly the calls `BudgetDatabase.fetchSchedules(budgetID:today:)` makes for each schedule (with the
/// stored `upcomingLength`, or "7" when no preference is stored), so the pure call is the read path's own logic.
enum ScheduleStatusReplay {
    static func replay(_ entry: [String: Any]) throws -> [ReplayMismatch] {
        let today = try OracleJSON.string(entry, "today")
        let length = (entry["upcomingLength"] as? String) ?? "7"
        var comparison = OracleComparison()

        let oracleDays = try OracleJSON.object(entry["upcomingDays"], "upcomingDays")
        comparison.compare(
            expected: try OracleValue(json: oracleDays["value"] ?? NSNull()),
            actual: .number(Double(ScheduleUpcomingLength.days(for: length, today: today))),
            path: "upcomingDays"
        )
        for (index, row) in try OracleJSON.objects(entry["rows"], "rows").enumerated() {
            let nextDate = try OracleJSON.string(row, "nextDate")
            let completed = row["completed"] as? Bool ?? false
            let hasTrans = row["hasTrans"] as? Bool ?? false
            let status = ScheduleStatus.resolve(
                nextDate: nextDate,
                completed: completed,
                hasMatchingTransaction: hasTrans,
                today: today,
                upcomingLength: length
            )
            comparison.compare(
                expected: try OracleValue(json: row["status"] ?? NSNull()),
                actual: .string(status.rawValue),
                path: "row\(index)[\(nextDate) \(completed ? "completed" : "open")/\(hasTrans ? "paid" : "unpaid")].status"
            )
        }
        return comparison.mismatches
    }
}
