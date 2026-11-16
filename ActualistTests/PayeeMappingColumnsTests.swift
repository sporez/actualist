import Testing
@testable import Actualist

/// `PayeeMappingColumns.target(in:)` replaces three hand-written alias checks.
/// This compares it with each of them for every combination of the columns.
struct PayeeMappingColumnsTests {
    private static let columnSets: [[String]] = [
        [], ["id"], ["targetId"], ["target_id"], ["id", "targetId"], ["id", "target_id"],
        ["targetId", "target_id"], ["id", "targetId", "target_id"],
    ]

    @Test(arguments: columnSets)
    func targetMatchesEachReplacedCheck(columnList: [String]) {
        let columns = Set(columnList)
        let owner = PayeeMappingColumns.target(in: columns)
        #expect(owner == Self.ternaryDeletedCopy(columns))
        #expect(owner == ["targetId", "target_id"].first(where: columns.contains))
    }

    private static func ternaryDeletedCopy(_ columns: Set<String>) -> String? {
        columns.contains("targetId") ? "targetId" : columns.contains("target_id") ? "target_id" : nil
    }
}
