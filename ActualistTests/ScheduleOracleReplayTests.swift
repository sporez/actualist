import Foundation
import Testing
@testable import Actualist

/// Replays the Schedules oracle contract through production schedule code: recurrence and status here, the
/// stateful operations in `ScheduleOracleStatefulReplayTests`. The partition test accounts for every case; see
/// `scripts/schedule-parity/README.md` ("Swift replay") for the compared and excluded fields. Mismatches a
/// registered divergence accounts for are split off by exact path; every other mismatch stays a strict failure.
struct ScheduleOracleReplayTests {
    @Test
    func manifestPartitionsEveryContractCase() throws {
        let cases = try ScheduleOracleFixture.cases()
        let manifest = try OracleManifest(
            domain: ScheduleOracleFixture.domain,
            manifestName: ScheduleOracleFixture.manifestName,
            fileName: ScheduleOracleFixture.fileName
        )
        let replayed = ScheduleOracleCaseIDs.recurrence + ScheduleOracleCaseIDs.status + ScheduleOracleCaseIDs.stateful
        let problems = manifest.partitionProblems(fixtureIDs: cases.ids, replayed: replayed)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test
    func fixtureMatchesThePinnedOracle() throws {
        let pin = try ParityOraclePin.load()
        let manifest = try ScheduleOracleFixture.manifest()
        let actual = try OracleJSON.object(manifest["actual"], "actual")
        #expect(actual["tag"] as? String == pin.tag)
        #expect(actual["commit"] as? String == pin.commit)
        #expect(manifest["timeZone"] as? String == ScheduleOracleFixture.timeZone.identifier)
        #expect(manifest["today"] as? String == "2026-10-11")
    }

    @Test(arguments: ScheduleOracleCaseIDs.recurrence)
    func replaysRecurrenceCase(caseID: String) throws {
        let cases = try ScheduleOracleFixture.cases()
        let results = try ScheduleRecurrenceReplay.replay(try cases.entry(caseID))
        #expect(!results.isEmpty, "\(caseID) replayed no queries")
        let split = KnownDivergenceSplit(results.flatMap(\.mismatches), knownPaths: Self.op47Paths[caseID] ?? [])
        #expect(split.strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, split.strict)))
        if !split.known.isEmpty {
            withKnownIssue("OP-47: a user skip on a before-weekend schedule starts the search the day after the next Monday, so a Monday occurrence is skipped") {
                #expect(split.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, split.known)))
            }
        }
    }

    @Test(arguments: ScheduleOracleCaseIDs.status)
    func replaysStatusCase(caseID: String) throws {
        let cases = try ScheduleOracleFixture.cases()
        let split = KnownDivergenceSplit(
            try ScheduleStatusReplay.replay(try cases.entry(caseID)),
            knownPaths: Self.op46Paths[caseID] ?? []
        )
        #expect(split.strict.isEmpty, Comment(rawValue: OracleComparison.report(caseID, split.strict)))
        if !split.known.isEmpty {
            withKnownIssue("OP-46: a month or year upcoming length counts from today's date, where Actual counts whole months from the first of the month") {
                #expect(split.known.isEmpty, Comment(rawValue: OracleComparison.report(caseID, split.known)))
            }
        }
    }

    // MARK: Known divergences (config/parity/known-divergences.json)

    /// OP-47: nextDateAfter on a before-weekend schedule.
    private static let op47Paths: [String: Set<String>] = [
        "gen-recur-015-monthly-1-p3-before": ["2026-09-18.nextDateAfter"],
        "gen-recur-032-monthly-1-p3-before-after_n_occurrences": ["2027-01-01.nextDateAfter"],
        "gen-recur-042-daily-1-before": ["2026-02-20.nextDateAfter"],
    ]

    /// OP-46: upcoming length in months or years.
    private static let op46Paths: [String: Set<String>] = [
        "status-2026-03-08-1-month": ["row39[2026-04-10 open/unpaid].status", "row40[2026-04-11 open/unpaid].status", "row41[2026-04-12 open/unpaid].status", "upcomingDays"],
        "status-2026-03-08-1-year": ["upcomingDays"],
        "status-2026-03-08-12-month": ["upcomingDays"],
        "status-2026-10-11-1-month": ["row39[2026-11-13 open/unpaid].status", "row40[2026-11-14 open/unpaid].status", "row41[2026-11-15 open/unpaid].status", "upcomingDays"],
        "status-2026-10-11-1-year": ["upcomingDays"],
        "status-2026-10-11-12-month": ["upcomingDays"],
        "status-2026-12-31-1-month": ["row39[2027-02-02 open/unpaid].status", "row40[2027-02-03 open/unpaid].status", "row41[2027-02-04 open/unpaid].status", "row42[2027-03-01 open/unpaid].status", "upcomingDays"],
        "status-2026-12-31-1-year": ["upcomingDays"],
        "status-2026-12-31-12-month": ["upcomingDays"],
        "status-2028-02-29-1-month": ["row37[2028-03-31 open/unpaid].status", "row38[2028-04-01 open/unpaid].status", "row39[2028-04-02 open/unpaid].status", "row40[2028-04-03 open/unpaid].status", "row41[2028-04-04 open/unpaid].status", "upcomingDays"],
        "status-2028-02-29-1-year": ["upcomingDays"],
        "status-2028-02-29-12-month": ["upcomingDays"],
    ]
}
