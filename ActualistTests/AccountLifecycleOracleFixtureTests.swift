import Foundation
import Testing

struct AccountLifecycleOracleFixtureTests {
    /// Message arrays are compared as multisets, so their order never decides a result.
    private static let messageKeys = ["operationMessages", "openServiceMessages", "repeatMessages"]

    private struct MessageDifference {
        var missing: [OracleValue] = []
        var extra: [OracleValue] = []

        var isEmpty: Bool {
            missing.isEmpty && extra.isEmpty
        }

        var summary: String {
            "missing [\(missing.map(\.canonical).joined(separator: " "))] unexpected [\(extra.map(\.canonical).joined(separator: " "))]"
        }
    }

    @Test func promotedFixturePinsActualVersionProvenanceAndAllCases() throws {
        let pin = try ParityOraclePin.load()
        let root = try ParityOraclePin.fixtureURL("AccountLifecycle")
        let manifest = try OracleJSONFileCache.jsonObject(at: root.appending(path: "account-lifecycle-manifest.json")) as? [String: Any]
        let actual = manifest?["actual"] as? [String: Any]
        let fixture = try OracleJSONFileCache.jsonObject(at: root.appending(path: "account-lifecycle-oracle.json")) as? [String: Any]
        let cases = fixture?["cases"] as? [[String: Any]] ?? []

        #expect(actual?["tag"] as? String == pin.tag)
        #expect(actual?["commit"] as? String == pin.commit)
        #expect(cases.count == 22)
        #expect(Set(cases.compactMap { $0["id"] as? String }).isSuperset(of: [
            "close-empty-history",
            "close-zero",
            "close-positive-on-to-on-history",
            "close-negative-on-to-on",
            "close-on-to-off-hidden-category",
            "close-off-to-on",
            "close-off-to-off",
            "unlink-simplefin",
            "close-unlink-undo-boundary",
            "schedule-close-reopen-eligibility",
        ]))
    }

    @Test func replayedAndOracleOnlyCasesPartitionEveryOracleCase() throws {
        let fixture = try AccountLifecycleOracleFixture.load()
        let replayed = Set(AccountLifecycleScenarios.replayedCaseIDs)

        #expect(replayed.count == AccountLifecycleScenarios.replayedCaseIDs.count)
        #expect(fixture.observedByCase.count == 22)
        #expect(replayed.isDisjoint(with: fixture.oracleOnlyCaseIDs))
        #expect(replayed.union(fixture.oracleOnlyCaseIDs) == Set(fixture.observedByCase.keys))
    }

    @Test(arguments: AccountLifecycleScenarios.replayedCaseIDs)
    func replaysOracleCase(_ caseID: String) async throws {
        let fixture = try AccountLifecycleOracleFixture.load()
        let expected = try fixture.observed(caseID)
        let actual = try await AccountLifecycleScenarios.replay(caseID)

        #expect(
            Set(actual.keys).isSubset(of: Set(expected.keys)),
            "\(caseID): replayed keys absent from the oracle observation"
        )
        let comparable = expected.filter { actual.keys.contains($0.key) }
        let scalarFields = comparable.filter { !Self.messageKeys.contains($0.key) }
        let mismatches = ReplayComparison.mismatches(
            expected: .object(scalarFields),
            actual: .object(actual),
            path: ""
        )
        let report = Comment(rawValue: "\(caseID): " + mismatches.map(\.summary).joined(separator: "; "))
        let messages = try Self.messageDifferences(caseID, expected: expected, actual: actual)
        let messageReport = Comment(rawValue: "\(caseID): " + messages.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.summary)" }
            .joined(separator: "; "))
        let operation = messages["operationMessages", default: MessageDifference()]

        #expect(mismatches.isEmpty, report)

        // The only known divergence is the intended rename trim/skip (OP-22); any other missing or
        // extra message fails outside its wrapper.
        switch caseID {
        case "rename-handler-input-boundary":
            // The source is "Original" (fixture input). Missing name cells for "Original" variants
            // are the intended trim/skip.
            let trimmedOrUnchanged = operation.missing.filter {
                Self.nameCell($0)?.trimmingCharacters(in: .whitespaces) == "Original"
            }
            #expect(operation.extra.isEmpty, messageReport)
            #expect(operation.missing.count == trimmedOrUnchanged.count, messageReport)
            withKnownIssue("OP-22: rename trims input and skips unchanged names (intended)") {
                #expect(trimmedOrUnchanged.isEmpty, messageReport)
            }
            #expect(messages.allSatisfy { $0.key == "operationMessages" || $0.value.isEmpty }, messageReport)
        default:
            #expect(messages.allSatisfy { $0.value.isEmpty }, messageReport)
        }
    }

    /// Multiset difference of each message array: oracle messages absent from the replay, and
    /// replayed messages the oracle does not emit.
    private static func messageDifferences(
        _ caseID: String,
        expected: [String: OracleValue],
        actual: [String: OracleValue]
    ) throws -> [String: MessageDifference] {
        var result: [String: MessageDifference] = [:]
        for key in messageKeys where expected[key] != nil || actual[key] != nil {
            let expectedItems = try messageItems(expected[key], caseID, key)
            var pending = try messageItems(actual[key], caseID, key)
            var difference = MessageDifference()
            for item in expectedItems {
                if let index = pending.firstIndex(of: item) {
                    pending.remove(at: index)
                } else {
                    difference.missing.append(item)
                }
            }
            difference.extra = pending
            result[key] = difference
        }
        return result
    }

    private static func messageItems(_ value: OracleValue?, _ caseID: String, _ key: String) throws -> [OracleValue] {
        switch value {
        case nil:
            []
        case .array(let items)?:
            items
        default:
            throw AccountLifecycleOracleError.malformedReplay("\(caseID): \(key) is not a message array")
        }
    }

    /// The value of an `accounts.name` cell message, or nil for any other message.
    private static func nameCell(_ message: OracleValue) -> String? {
        guard case .object(let fields) = message,
              case .string("accounts")? = fields["dataset"],
              case .string("name")? = fields["column"],
              case .string(let value)? = fields["value"]
        else {
            return nil
        }
        return value
    }
}
