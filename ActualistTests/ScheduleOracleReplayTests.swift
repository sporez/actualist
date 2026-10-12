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
        let mismatches = results.flatMap(\.mismatches)
        #expect(mismatches.isEmpty, Comment(rawValue: OracleComparison.report(caseID, mismatches)))
    }

    @Test(arguments: ScheduleOracleCaseIDs.status)
    func replaysStatusCase(caseID: String) throws {
        let cases = try ScheduleOracleFixture.cases()
        let mismatches = try ScheduleStatusReplay.replay(try cases.entry(caseID))
        #expect(mismatches.isEmpty, Comment(rawValue: OracleComparison.report(caseID, mismatches)))
    }
}
