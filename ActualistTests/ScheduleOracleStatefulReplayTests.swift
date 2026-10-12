import Foundation
import Testing
@testable import Actualist

/// Stateful Schedules cases. `replaysScheduleSteps` seeds the fixture's upstream rows before each step and runs
/// the production operation; `replaysScheduleCreation` replays `createSchedule` for each setup schedule. See
/// `scripts/schedule-parity/README.md` ("Swift replay"). Mismatches a registered divergence accounts for are split
/// off by exact path; every other mismatch stays a strict failure.
@MainActor
struct ScheduleOracleStatefulReplayTests {
    @Test(arguments: ScheduleOracleCaseIDs.stateful)
    func replaysScheduleSteps(caseID: String) async throws {
        let cases = try ScheduleOracleFixture.cases()
        let results = try await ScheduleStatefulReplay.replaySteps(try cases.entry(caseID))
        #expect(!results.isEmpty, "\(caseID) replayed no steps")

        var remaining = results.flatMap(\.mismatches)
        func take(_ table: [String: Set<String>]) -> [ReplayMismatch] {
            guard let paths = table[caseID] else { return [] }
            let split = KnownDivergenceSplit(remaining, knownPaths: paths)
            remaining = split.strict
            return split.known
        }
        let op51 = take(Self.op51Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if !op51.isEmpty {
            withKnownIssue("OP-51: skipping a one-time schedule is refused, where Actual leaves it unchanged") {
                #expect(op51.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op51)))
            }
        }
    }

    @Test(arguments: ScheduleOracleCaseIDs.stateful)
    func replaysScheduleCreation(caseID: String) async throws {
        let cases = try ScheduleOracleFixture.cases()
        let results = try await ScheduleStatefulReplay.replayCreation(try cases.entry(caseID))
        var remaining = results.flatMap(\.mismatches)
        func take(_ table: [String: Set<String>]) -> [ReplayMismatch] {
            guard let paths = table[caseID] else { return [] }
            let split = KnownDivergenceSplit(remaining, knownPaths: paths)
            remaining = split.strict
            return split.known
        }
        let op52 = take(Self.op52Paths)
        let op53 = take(Self.op53Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if !op52.isEmpty {
            withKnownIssue("OP-52: a schedule created on a day starts its next-date search at that day, where Actual starts at the day before in a time zone behind UTC") {
                #expect(op52.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op52)))
            }
        }
        if !op53.isEmpty {
            withKnownIssue("OP-53: creating a schedule on a closed account is refused, where Actual accepts it") {
                #expect(op53.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op53)))
            }
        }
    }

    // MARK: Known divergences (config/parity/known-divergences.json)

    /// OP-51: skip on a one-time schedule.
    private static let op51Paths: [String: Set<String>] = [
        "skip-one-time": ["step0(skip).completes"],
    ]

    /// OP-52: initial next date on creation.
    private static let op52Paths: [String: Set<String>] = [
        "create-negative-offset-timezone": ["created.nextDates.schedule-s1.base_next_date", "created.nextDates.schedule-s1.local_next_date"],
    ]

    /// OP-53: creating a schedule on a closed account.
    private static let op53Paths: [String: Set<String>] = [
        "advance-closed-account-skipped": ["created.completes"],
    ]
}
