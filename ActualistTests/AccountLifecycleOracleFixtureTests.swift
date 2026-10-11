import Foundation
import Testing

struct AccountLifecycleOracleFixtureTests {
    /// Message arrays are compared as multisets, so their order never decides a result.
    private static let messageKeys = ["operationMessages", "openServiceMessages", "repeatMessages"]

    /// Default-valued cells the transfer legs write that the pinned Actual does not emit (OP-10).
    private static let transferLegDefaults: [String: OracleValue] = [
        "isParent": .number(0),
        "isChild": .number(0),
        "tombstone": .number(0),
        "parent_id": .null,
        "error": .null,
        "category": .null,
    ]

    /// Default-valued cells a scheduled post writes that the oracle does not emit (OP-13).
    private static let scheduleDefaults: [String: OracleValue] = [
        "description": .null,
        "category": .null,
        "notes": .null,
        "tombstone": .number(0),
        "isParent": .number(0),
        "parent_id": .null,
    ]

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
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: "account-lifecycle-manifest.json"))
        ) as? [String: Any]
        let actual = manifest?["actual"] as? [String: Any]
        let fixture = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: "account-lifecycle-oracle.json"))
        ) as? [String: Any]
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
        let repeated = messages["repeatMessages", default: MessageDifference()]
        let service = messages["openServiceMessages", default: MessageDifference()]

        // OP-13's only known scalar gap is the scheduled post's missing sort_order.
        let knownScalarGap: (ReplayMismatch) -> Bool = { mismatch in
            caseID == "schedule-close-reopen-eligibility" && Self.isScheduleSortGap(mismatch)
        }
        #expect(mismatches.allSatisfy(knownScalarGap), report)

        // Each known divergence wraps only its own "has extras/gaps" check. Its allowed cells
        // are checked strictly, and any other missing or extra message fails outside the wrapper.
        switch caseID {
        case "close-positive-on-to-on-history",
             "close-negative-on-to-on",
             "close-on-to-off-hidden-category",
             "close-off-to-on",
             "close-off-to-off",
             "close-split-balance":
            #expect(operation.missing.isEmpty, messageReport)
            #expect(operation.extra.allSatisfy { Self.matchesDefault($0, Self.transferLegDefaults) }, messageReport)
            withKnownIssue("OP-10: transfer legs write default-valued cells the pinned Actual does not emit") {
                #expect(operation.extra.isEmpty, messageReport)
            }
            #expect(messages.allSatisfy { $0.key == "operationMessages" || $0.value.isEmpty }, messageReport)
        case "rename-handler-input-boundary":
            // The source is "Original" and the peer "Duplicate" (fixture input). Missing name cells
            // for "Original" variants are the intended trim/skip; a missing "Duplicate" is OP-11.
            let trimmedOrUnchanged = operation.missing.filter {
                Self.nameCell($0)?.trimmingCharacters(in: .whitespaces) == "Original"
            }
            let duplicate = operation.missing.filter { Self.nameCell($0) == "Duplicate" }
            #expect(operation.extra.isEmpty, messageReport)
            #expect(operation.missing.count == trimmedOrUnchanged.count + duplicate.count, messageReport)
            withKnownIssue("OP-22: rename trims input and skips unchanged names (intended)") {
                #expect(trimmedOrUnchanged.isEmpty, messageReport)
            }
            withKnownIssue("OP-11: rename refuses an exact duplicate name") {
                #expect(duplicate.isEmpty, messageReport)
            }
            #expect(messages.allSatisfy { $0.key == "operationMessages" || $0.value.isEmpty }, messageReport)
        case "reopen-repeat-history":
            withKnownIssue("OP-12: reopening an open account writes no closed cell") {
                #expect(repeated.isEmpty, messageReport)
            }
            #expect(messages.allSatisfy { $0.key == "repeatMessages" || $0.value.isEmpty }, messageReport)
        case "schedule-close-reopen-eligibility":
            #expect(service.missing.allSatisfy(Self.isScheduleMissingCell), messageReport)
            #expect(service.extra.allSatisfy { Self.matchesDefault($0, Self.scheduleDefaults) }, messageReport)
            withKnownIssue("OP-13: scheduled posts omit the sort_order and reconciled cells") {
                #expect(service.isEmpty && mismatches.isEmpty, messageReport)
            }
            #expect(messages.allSatisfy { $0.key == "openServiceMessages" || $0.value.isEmpty }, messageReport)
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

    private static func isScheduleSortGap(_ mismatch: ReplayMismatch) -> Bool {
        mismatch.path == "openScheduledTransactions[id4].sort_order" && mismatch.actual == "null"
    }

    /// A transaction cell message whose column is in `defaults` and whose value equals that default.
    private static func matchesDefault(_ message: OracleValue, _ defaults: [String: OracleValue]) -> Bool {
        guard case .object(let fields) = message,
              case .string("transactions")? = fields["dataset"],
              case .string(let column)? = fields["column"],
              let value = fields["value"]
        else {
            return false
        }
        return defaults[column] == value
    }

    private static func isScheduleMissingCell(_ message: OracleValue) -> Bool {
        guard case .object(let fields) = message,
              case .string("transactions")? = fields["dataset"],
              case .string(let column)? = fields["column"]
        else {
            return false
        }
        return column == "sort_order" || column == "reconciled"
    }
}
