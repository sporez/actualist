import CryptoKit
import Foundation
import Testing
@testable import Actualist

struct ActualCoreSplitOracleFixtureTests {
    @Test func manifestPinsActualAndEveryCommittedFixtureHash() throws {
        let manifest = try decode(Manifest.self, from: fixtureDirectory.appending(path: "manifest.json"))

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.actual.tag == "v26.8.1")
        #expect(manifest.actual.commit == "063df03763ca772b51f6264752b88ddec22cfb8a")
        #expect(manifest.actual.packageVersion == "26.8.1")
        #expect(manifest.amountUnits == "integer minor units")
        #expect(manifest.rounding == "JavaScript Math.round: ties toward positive infinity")
        #expect(manifest.sourceFiles.count >= 10)

        for fixture in manifest.fixtures {
            let url = repositoryRoot.appending(path: fixture.path)
            let data = try Data(contentsOf: url)
            #expect(SHA256.hash(data: data).hex == fixture.sha256)
            let value = try JSONDecoder().decode(FixtureEnvelope.self, from: data)
            #expect(value.schemaVersion == manifest.schemaVersion)
            #expect(value.oracle.commit == manifest.actual.commit)
            #expect(value.oracle.packageVersion == manifest.actual.packageVersion)
            #expect(value.cases.count == fixture.caseCount)
            #expect(Set(value.cases.map(\.id)).count == value.cases.count)
        }
    }

    @Test func ruleVectorsLockOneBasedTargetsAndJavaScriptTieRounding() throws {
        let fixture = try decode(
            SplitRuleFixture.self,
            from: fixtureDirectory.appending(path: "split-rule-cases.json")
        )
        let cases = Dictionary(uniqueKeysWithValues: fixture.cases.map { ($0.id, $0) })

        let indexes = try #require(cases["index-zero-whole-transaction-and-one-based-children"])
        #expect(indexes.actions?.compactMap(\.options?.splitIndex) == [0, 1, 1, 2, 2])
        #expect(indexes.expected.children.map(\.amount) == [-4_000, -6_000])

        let negativeTie = try #require(cases["negative-half-percent-rounding"])
        #expect(negativeTie.expected.children.map(\.amount) == [-2, -3])
        let positiveTie = try #require(cases["positive-half-percent-rounding"])
        #expect(positiveTie.expected.children.map(\.amount) == [3, 2])

        let formula = try #require(cases["formula-and-remainder"])
        #expect(formula.expected.children.map(\.amount) == [30_000, 70_000])
        let childInput = try #require(cases["effective-child-input-is-not-split"])
        #expect(childInput.expected.parent.isChild)
        #expect(childInput.expected.children.isEmpty)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureDirectory: URL {
        repositoryRoot.appending(path: "ActualistTests/Fixtures/ActualCore26_8_1/Splits")
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private struct Manifest: Decodable {
    let schemaVersion: Int
    let actual: OracleIdentity
    let amountUnits: String
    let rounding: String
    let sourceFiles: [SourceFile]
    let fixtures: [Fixture]

    struct SourceFile: Decodable {
        let path: String
        let sha256: String
    }

    struct Fixture: Decodable {
        let path: String
        let sha256: String
        let caseCount: Int
    }
}

private struct OracleIdentity: Decodable {
    let tag: String
    let commit: String
    let packageVersion: String
}

private struct FixtureEnvelope: Decodable {
    let schemaVersion: Int
    let oracle: OracleIdentity
    let cases: [CaseIdentity]
}

private struct CaseIdentity: Decodable {
    let id: String
}

private struct SplitRuleFixture: Decodable {
    let cases: [SplitRuleCase]
}

private struct SplitRuleCase: Decodable {
    let id: String
    let actions: [Action]?
    let expected: Family

    struct Action: Decodable {
        let options: Options?
    }

    struct Options: Decodable {
        let splitIndex: Int?
    }

    struct Family: Decodable {
        let parent: Transaction
        let children: [Transaction]
    }

    struct Transaction: Decodable {
        let amount: Int
        let isChild: Bool
    }
}

private extension Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
