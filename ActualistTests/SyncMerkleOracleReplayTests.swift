import Foundation
import Testing
@testable import Actualist

/// Replays the SyncMerkle oracle contract (upstream `_fullSync` against its mock
/// sync server) through Actualist's production sync (`SyncMerkleOracleReplay`).
/// Each case compares the outcome, the server's and the client's final message
/// sets, merkle agreement and the client's payee rows. Request sequences are not
/// compared: Actualist uploads its outbox in batches with an upload
/// confirmation, and after a rebuild retries ten more rounds before giving up
/// where upstream gives up at once, so the requests differ by design while the
/// outcome and final state must match. A mid-sync local commit is minted by each
/// client's own clock, so for those cases the final sets compare with the minted
/// timestamps exchanged.
@MainActor
struct SyncMerkleOracleReplayTests {
    private static let domain = "SyncMerkle"
    private static let fileName = "sync-merkle-contract.json"
    private static let manifestName = "sync-merkle-manifest.json"

    private func fixture() throws -> OracleFixtureCases {
        try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "result")
    }

    private func header() throws -> [String: Any] {
        let url = try ParityOraclePin.fixtureURL(Self.domain).appending(path: Self.fileName)
        return try OracleJSON.object(OracleJSONFileCache.jsonObject(at: url), Self.fileName)
    }

    @Test
    func manifestPartitionsEveryContractCase() throws {
        let manifest = try OracleManifest(domain: Self.domain, manifestName: Self.manifestName, fileName: Self.fileName)
        let problems = manifest.partitionProblems(fixtureIDs: try fixture().ids, replayed: SyncMerkleOracleCaseIDs.replayed)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test
    func fixtureMatchesThePinnedOracle() throws {
        let pin = try ParityOraclePin.load()
        let oracle = try OracleJSON.object(try header()["oracle"], "oracle")
        #expect(oracle["tag"] as? String == pin.tag)
        #expect(oracle["commit"] as? String == pin.commit)
    }

    @Test(arguments: SyncMerkleOracleCaseIDs.replayed)
    func replaysSyncMerkleCase(caseID: String) async throws {
        let entry = try fixture().entry(caseID)
        let result = try OracleJSON.object(entry["result"], "result")
        let final = try OracleJSON.object(result["final"], "final")
        let expectedOutcome = try OracleJSON.string(result, "outcome")
        let observed = try await SyncMerkleOracleReplay.replay(entry, header: try header())
        var mismatches: [String] = []

        if observed.outcome != expectedOutcome {
            mismatches.append("outcome: expected \(expectedOutcome), actual \(observed.outcome)")
        }
        if observed.merkleEqual != (final["merkleEqual"] as? Bool) {
            mismatches.append("merkleEqual: expected \(String(describing: final["merkleEqual"])), actual \(observed.merkleEqual)")
        }
        // Mid-sync commits: swap each timestamp this client minted for upstream's
        // minted timestamp of the same row, so the sets are comparable.
        var upstreamMintedByRow: [String: [String]] = [:]
        for minted in try OracleJSON.objects(result["mintedCommits"], "mintedCommits") {
            upstreamMintedByRow[try OracleJSON.string(minted, "row"), default: []]
                .append(try OracleJSON.string(minted, "timestamp"))
        }
        let upstreamMintedCount = upstreamMintedByRow.values.reduce(0) { $0 + $1.count }
        if observed.mintedRows.count != upstreamMintedCount {
            mismatches.append("minted commits: expected \(upstreamMintedCount), actual \(observed.mintedRows.count)")
        }
        for key in ["serverTimestamps", "clientTimestamps"] {
            let summary = try OracleJSON.object(final[key], key)
            var available = upstreamMintedByRow
            let comparable = (key == "serverTimestamps" ? observed.serverTimestamps : observed.clientTimestamps)
                .sorted()
                .map { timestamp -> String in
                    guard let row = observed.mintedRows[timestamp], var queue = available[row], !queue.isEmpty else {
                        return timestamp
                    }
                    let upstream = queue.removeFirst()
                    available[row] = queue
                    return upstream
                }
            let digest = SyncMerkleOracleReplay.digest(comparable)
            if comparable.count != summary["count"] as? Int || digest != summary["sha256"] as? String {
                mismatches.append(
                    "\(key): expected \(summary["count"] ?? "?") (\(summary["sha256"] ?? "?")), "
                        + "actual \(comparable.count) (\(digest))"
                )
            }
        }
        let payees = try OracleJSON.object(final["clientPayees"], "clientPayees")
        if SyncMerkleOracleReplay.digest(observed.clientPayees) != payees["sha256"] as? String {
            mismatches.append(
                "clientPayees: expected \(payees["count"] ?? "?") rows, actual \(observed.clientPayees.count); "
                    + "expected items \(payees["items"] ?? "digest only"), actual \(observed.clientPayees.sorted().prefix(20))"
            )
        }
        #expect(mismatches.isEmpty, Comment(rawValue: "\(caseID)\n" + mismatches.joined(separator: "\n")))
    }
}
