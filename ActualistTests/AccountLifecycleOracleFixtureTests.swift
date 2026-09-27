import Foundation
import Testing

struct AccountLifecycleOracleFixtureTests {
    @Test func promotedFixturePinsActualVersionProvenanceAndAllCases() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ActualCore26_9_0/AccountLifecycle")
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: "account-lifecycle-manifest.json"))
        ) as? [String: Any]
        let actual = manifest?["actual"] as? [String: Any]
        let fixture = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: "account-lifecycle-oracle.json"))
        ) as? [String: Any]
        let cases = fixture?["cases"] as? [[String: Any]] ?? []

        #expect(actual?["tag"] as? String == "v26.9.0")
        #expect(actual?["commit"] as? String == "59fe126f637d858c061e1eeedbef5436c8f2225a")
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
}
