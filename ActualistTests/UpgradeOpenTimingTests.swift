import Foundation
import GRDB
import Testing
@testable import Actualist

/// Opt-in diagnostic, never part of a normal unit run. Set
/// `TEST_RUNNER_ACTUALIST_UPGRADE_TIMING_DB=<path to a budget db.sqlite>` on the
/// host so `scripts/test.sh unit UpgradeOpenTimingTests` measures the one-time
/// open cost for a file that has never been opened by a build with the merkle
/// rebuild (no `merkle-v1` marker): first open, then second open of the same copy.
@MainActor
@Suite(
    "Upgrade open timing (opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["ACTUALIST_UPGRADE_TIMING_DB"] != nil)
)
struct UpgradeOpenTimingTests {
    @Test func measuresFirstAndSecondOpen() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["ACTUALIST_UPGRADE_TIMING_DB"])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upgrade-open-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("db.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)

        let rowCount = try removeMarkerAndCount(at: copy)
        let clock = ContinuousClock()
        let nodeID = "0123456789abcdef"

        let first = try clock.measure {
            _ = try BudgetDatabase(databaseURL: copy, localNodeID: nodeID)
        }
        let second = try clock.measure {
            _ = try BudgetDatabase(databaseURL: copy, localNodeID: nodeID)
        }
        let line = "UPGRADE-TIMING messages_crdt=\(rowCount) firstOpen=\(first) secondOpen=\(second)"
        print(line)
        // The runner's stdout is not surfaced by the wrapper's log; leave the result beside the source.
        let report = URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent("timing.txt")
        try? (line + "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    private func removeMarkerAndCount(at url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.write { db in
            if try db.tableExists("actualist_local_migrations") {
                try db.execute(
                    sql: "DELETE FROM actualist_local_migrations WHERE name = ?",
                    arguments: [BudgetDatabase.merkleRebuildMigration]
                )
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0
        }
    }
}
