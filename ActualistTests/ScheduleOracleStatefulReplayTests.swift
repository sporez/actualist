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
        let op48 = take(Self.op48Paths)
        let op49 = take(Self.op49Paths)
        let op50 = take(Self.op50Paths)
        let op51 = take(Self.op51Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if !op48.isEmpty {
            withKnownIssue("OP-48: advancing a before-weekend schedule whose next date was moved to a Friday never leaves that Friday") {
                #expect(op48.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op48)))
            }
        }
        if !op49.isEmpty {
            withKnownIssue("OP-49: a paid manual recurring schedule moves to the occurrence after the paid one, where Actual moves to the first occurrence from today") {
                #expect(op49.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op49)))
            }
        }
        if !op50.isEmpty {
            withKnownIssue("OP-50: a between amount stored high to low is unsupported, so the schedule is never auto-posted") {
                #expect(op50.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op50)))
            }
        }
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
        let op50 = take(Self.op50CreationPaths)
        let op52 = take(Self.op52Paths)
        let op53 = take(Self.op53Paths)

        #expect(remaining.isEmpty, Comment(rawValue: OracleComparison.report(caseID, remaining)))
        if !op50.isEmpty {
            withKnownIssue("OP-50: a between amount stored high to low is unsupported, so creating the schedule is refused") {
                #expect(op50.isEmpty, Comment(rawValue: OracleComparison.report(caseID, op50)))
            }
        }
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

    /// OP-48: before-weekend advancement stays on a Friday.
    private static let op48Paths: [String: Set<String>] = [
        "advance-weekend-before-catchup": ["step0(advance).effective.schedule-s1.nextDate", "step0(advance).effective.schedule-s1.status", "step0(advance).nextDates.schedule-s1.local_next_date"],
        "gen-state-006": ["step2(advance).effective.schedule-s1.nextDate", "step2(advance).effective.schedule-s1.status", "step2(advance).nextDates.schedule-s1.local_next_date", "step2(advance).transactions"],
        "gen-state-012": ["step1(advance).effective.schedule-s2.nextDate", "step1(advance).effective.schedule-s2.status", "step1(advance).nextDates.schedule-s2.local_next_date", "step1(advance).transactions"],
        "gen-state-016": ["step0(advance).effective.schedule-s1.nextDate", "step0(advance).nextDates.schedule-s1.local_next_date", "step0(advance).transactions"],
    ]

    /// OP-49: paid manual recurring schedule advances one occurrence.
    private static let op49Paths: [String: Set<String>] = [
        "advance-paid-recurring-no-post": ["step1(advance).effective.schedule-s1.nextDate", "step1(advance).effective.schedule-s1.status", "step1(advance).nextDates.schedule-s1.local_next_date"],
    ]

    /// OP-50: a between amount stored high to low.
    private static let op50Paths: [String: Set<String>] = [
        "advance-approx-amount": ["step0(advance).effective.schedule-s1.status", "step0(advance).refusals", "step0(advance).transactions"],
    ]

    /// OP-51: skip on a one-time schedule.
    private static let op51Paths: [String: Set<String>] = [
        "skip-one-time": ["step0(skip).completes"],
    ]

    /// OP-52: initial next date on creation.
    private static let op52Paths: [String: Set<String>] = [
        "create-negative-offset-timezone": ["created.nextDates.schedule-s1.base_next_date", "created.nextDates.schedule-s1.local_next_date"],
    ]

    /// OP-50 in `createSchedule`: the same high-to-low range, refused before anything is written.
    private static let op50CreationPaths: [String: Set<String>] = [
        "advance-approx-amount": ["created.completes"],
    ]

    /// OP-53: creating a schedule on a closed account.
    private static let op53Paths: [String: Set<String>] = [
        "advance-closed-account-skipped": ["created.completes"],
    ]
}
