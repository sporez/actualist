import CryptoKit
import Foundation
import Testing
@testable import Actualist

struct ActualCoreReconciliationOracleFixtureTests {
    @Test func manifestPinsActualSourcesGeneratorAndFixture() throws {
        let manifest = try decode(
            ReconciliationManifest.self,
            from: fixtureDirectory.appending(path: "reconciliation-manifest.json")
        )
        let fixtureURL = repositoryRoot.appending(path: manifest.fixture.path)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(ReconciliationFixture.self, from: fixtureData)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.actual.tag == "v26.9.0")
        #expect(manifest.actual.commit == "59fe126f637d858c061e1eeedbef5436c8f2225a")
        #expect(manifest.actual.packageVersion == "26.9.0")
        #expect(manifest.amountUnits == "integer minor units")
        #expect(manifest.lastReconciledStorage == "new Date().getTime().toString() milliseconds")
        #expect(manifest.sourceFiles.count == 9)
        #expect(manifest.sourceFiles.allSatisfy { $0.sha256.count == 64 })
        #expect(SHA256.hash(data: fixtureData).reconciliationHex == manifest.fixture.sha256)
        #expect(fixture.schemaVersion == manifest.schemaVersion)
        #expect(fixture.oracle.commit == manifest.actual.commit)
        #expect(fixture.cases.count == manifest.fixture.caseCount)
        #expect(Set(fixture.cases.map(\.id)).count == fixture.cases.count)
    }

    @Test func executableContractCoversReadFinishAdjustmentLockAndUnlock() throws {
        let fixture = try decode(
            ReconciliationFixture.self,
            from: fixtureDirectory.appending(path: "reconciliation-contract.json")
        )
        let cases = Dictionary(uniqueKeysWithValues: fixture.cases.map { ($0.id, $0.value) })

        let cleared = try #require(cases["cleared-balance"] as? [String: Any])
        #expect(cleared["balance"] as? Int == -8_300)
        let query = try #require(cleared["query"] as? [String: Any])
        let state = try #require(query["state"] as? [String: Any])
        let options = try #require(state["tableOptions"] as? [String: Any])
        #expect(options["splits"] as? String == "none")

        let finish = try #require(cases["finish"] as? [String: Any])
        #expect(finish["zeroDifferenceLocks"] as? Int == 1)
        #expect(finish["nonzeroDifferenceLocks"] as? Int == 0)

        let adjustment = try #require(cases["adjustment-rule-projection"] as? [String: Any])
        let realized = try #require((adjustment["realized"] as? [String: Any]))
        #expect(realized["account"] as? String == "checking")
        #expect(realized["cleared"] as? Bool == true)
        #expect(realized["reconciled"] as? Bool == false)
        #expect(realized["notes"] as? String == "Reconciliation balance adjustment")
        #expect((adjustment["splitAdded"] as? [Any])?.count == 1)

        let lock = try #require(cases["lock"] as? [[String: Any]])
        #expect(Set(lock.compactMap { $0["id"] as? String }) == ["simple", "parent", "child-a", "child-b"])
        #expect(lock.allSatisfy { $0["reconciled"] as? Bool == true })

        let unlock = try #require(cases["unlock"] as? [[String: Any]])
        #expect(unlock.first?["reconciled"] as? Bool == false)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureDirectory: URL {
        repositoryRoot.appending(path: "ActualistTests/Fixtures/ActualCore26_9_0/Reconciliation")
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private struct ReconciliationManifest: Decodable {
    let schemaVersion: Int
    let actual: ReconciliationOracleIdentity
    let amountUnits: String
    let lastReconciledStorage: String
    let sourceFiles: [SourceFile]
    let fixture: Fixture

    struct SourceFile: Decodable {
        let sha256: String
    }

    struct Fixture: Decodable {
        let path: String
        let sha256: String
        let caseCount: Int
    }
}

private struct ReconciliationOracleIdentity: Decodable {
    let tag: String
    let commit: String
    let packageVersion: String
}

private struct ReconciliationFixture: Decodable {
    let schemaVersion: Int
    let oracle: ReconciliationOracleIdentity
    let cases: [Case]

    struct Case: Decodable {
        let id: String
        let value: Any

        enum CodingKeys: CodingKey { case id, value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            value = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(try container.decode(JSONValue.self, forKey: .value))
            )
        }
    }
}

private enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private extension Digest {
    var reconciliationHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
