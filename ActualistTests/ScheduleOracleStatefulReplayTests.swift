import Foundation
import Testing
@testable import Actualist

/// Stateful Schedules cases. `replaysScheduleSteps` seeds the fixture's upstream rows before each step and runs
/// the production operation; `replaysScheduleCreation` replays `createSchedule` for each setup schedule. See
/// `scripts/schedule-parity/README.md` ("Swift replay"). Mismatches a registered divergence accounts for are split
/// off by exact path; every other mismatch stays a strict failure. A listed case always runs its known-issue block,
/// so a divergence that stops occurring fails until its table entry, marker and registry entry are removed.
@MainActor
struct ScheduleOracleStatefulReplayTests {
    @Test(arguments: ScheduleOracleCaseIDs.stateful)
    func replaysScheduleSteps(caseID: String) async throws {
        let cases = try ScheduleOracleFixture.cases()
        let results = try await ScheduleStatefulReplay.replaySteps(try cases.entry(caseID))
        #expect(!results.isEmpty, "\(caseID) replayed no steps")

        var remaining = results.flatMap(\.mismatches)
        func take(_ table: [String: Set<String>]) -> [ReplayMismatch]? {
            guard let paths = table[caseID] else { return nil }
            let split = KnownDivergenceSplit(remaining, knownPaths: paths)
            remaining = split.strict
            return split.known
        }
        let op51 = take(Self.op51Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if let op51 {
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
        func take(_ table: [String: Set<String>]) -> [ReplayMismatch]? {
            guard let paths = table[caseID] else { return nil }
            let split = KnownDivergenceSplit(remaining, knownPaths: paths)
            remaining = split.strict
            return split.known
        }
        let op53 = take(Self.op53Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if let op53 {
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

    /// OP-53: creating a schedule on a closed account.
    private static let op53Paths: [String: Set<String>] = [
        "advance-closed-account-skipped": ["created.completes"],
    ]
}
