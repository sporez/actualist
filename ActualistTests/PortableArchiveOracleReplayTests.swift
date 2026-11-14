import Foundation
import Testing
@testable import Actualist

/// Round trip of the budget ZIP between Actual and Actualist, replayed from the PortableArchive
/// fixture (`scripts/portable-archive-parity/README.md`). Direction A imports Actual's own export
/// through the production portable import and compares the opened database with Actual's digest.
/// Direction B compares what Actual reads from an Actualist export with Actual's own copy (B1) and
/// checks the committed Actualist export against the current exporter (B2). The sync reset empties
/// the `messages_*` tables, which the digest only counts.
@Suite @MainActor
struct PortableArchiveOracleReplayTests {
    nonisolated private static let producerFlag = "ACTUALIST_PRODUCE_PORTABLE_EXPORT"
    private static let producerOutput = "ACTUALIST_PORTABLE_EXPORT_OUTPUT"

    private static func sameJSON(_ left: Any?, _ right: Any?) -> Bool {
        guard let left, let right, JSONSerialization.isValidJSONObject(left), JSONSerialization.isValidJSONObject(right) else { return false }
        let options: JSONSerialization.WritingOptions = [.sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: left, options: options))
            == (try? JSONSerialization.data(withJSONObject: right, options: options))
    }

    private func actualDigest() throws -> PortableTableDigest {
        let file = try PortableArchiveOracleReplay.fixtureJSON("actual-export-digest.json")
        return try PortableTableDigest(fixture: try OracleJSON.object(file["digest"], "digest"))
    }

    private func importActualExport() async throws -> PortableArchiveOracleReplay.Imported {
        try await PortableArchiveOracleReplay.importArchive(
            at: try PortableArchiveOracleReplay.fixtureURL("actual-export.zip")
        )
    }

    @Test func importedDatabaseMatchesActualsDigest() async throws {
        let imported = try await importActualExport()
        let problems = try PortableArchiveOracleReplay.digest(of: imported)
            .differences(from: try actualDigest(), expectedName: "Actual", actualName: "Actualist")
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test func importedBalancesMatchActuals() async throws {
        let imported = try await importActualExport()
        let file = try PortableArchiveOracleReplay.fixtureJSON("actual-export-digest.json")
        let expected = try #require(file["balances"] as? [[String: Any]])
        let actual = try await PortableArchiveOracleReplay.balances(of: imported)
        var problems: [String] = []
        for account in expected {
            let id = try OracleJSON.string(account, "id")
            let balance = (account["balance"] as? NSNumber)?.intValue
            if actual[id] != balance { problems.append("account \(id): Actual \(balance.map(String.init) ?? "nil"), Actualist \(actual[id].map(String.init) ?? "missing")") }
        }
        if actual.count != expected.count { problems.append("account count: Actual \(expected.count), Actualist \(actual.count)") }
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    /// B1: what Actual reads from the Actualist export equals what it read from its own export.
    @Test func actualReadsTheActualistExportAsItsOwn() throws {
        let file = try PortableArchiveOracleReplay.fixtureJSON("actualist-export-digest.json")
        let readByActual = try PortableTableDigest(fixture: try OracleJSON.object(file["afterActualImport"], "afterActualImport"))
        var problems = readByActual.differences(from: try actualDigest(), expectedName: "Actual export", actualName: "Actualist export")
        let source = try PortableArchiveOracleReplay.fixtureJSON("actual-export-digest.json")
        if !Self.sameJSON(source["balances"], file["balances"]) {
            problems.append("balances: Actual \(String(describing: source["balances"])), Actualist export \(String(describing: file["balances"]))")
        }
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    /// B2: the current exporter on a fresh import of Actual's export writes the database recorded
    /// for the committed `actualist-export.zip`. Regenerate that input with
    /// `scripts/portable-archive-parity/produce-actualist-export.sh`, then `generate.mjs`.
    @Test func currentExporterReproducesTheCommittedExport() async throws {
        let file = try PortableArchiveOracleReplay.fixtureJSON("actualist-export-digest.json")
        let recorded = try PortableTableDigest(fixture: try OracleJSON.object(file["zip"], "zip"))
        let imported = try await importActualExport()
        let exported = try await PortableArchiveOracleReplay.export(imported)
        let database = try PortableArchiveOracleReplay.databaseURL(inArchive: exported)
        let problems = try PortableTableDigest(databaseAt: database)
            .differences(from: recorded, expectedName: "committed export", actualName: "current export")
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    /// The producer step of `produce-actualist-export.sh`; does nothing in a normal run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment[producerFlag] == "1"))
    func produceActualistExport() async throws {
        let output = try #require(ProcessInfo.processInfo.environment[Self.producerOutput])
        let imported = try await importActualExport()
        let exported = try await PortableArchiveOracleReplay.export(imported)
        let destination = URL(fileURLWithPath: output)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: exported, to: destination)
    }
}
