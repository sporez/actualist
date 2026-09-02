import Foundation
import Testing
@testable import Actualist

@Suite struct BudgetActionInverseTests {
    @Test func assignSummaryCodableRoundTrips() throws {
        let summary = BudgetActionSummary.assign(AssignBudgetAction(
            month: "2026-07",
            categoryID: "groceries",
            before: 50_000,
            after: 62_500
        ))
        try #expect(summary.codableRoundTrip() == summary)
    }

    @Test func moveSummaryCodableRoundTrips() throws {
        let summary = BudgetActionSummary.move(MoveBudgetAction(
            month: "2026-07",
            legs: [
                BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000),
                BudgetMoveLeg(fromCategoryID: nil, toCategoryID: "utilities", amount: 250)
            ]
        ))
        try #expect(summary.codableRoundTrip() == summary)
    }

    @Test func assignInverseCodableRoundTrips() throws {
        let inverse = BudgetActionInverse.assign(AssignBudgetAction(
            month: "2026-08",
            categoryID: "utilities",
            before: 0,
            after: 3_000
        ))
        try #expect(inverse.codableRoundTrip() == inverse)
    }

    @Test func moveInverseCodableRoundTrips() throws {
        let legs = [BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000)]
        let inverse = BudgetActionInverse.move(MoveBudgetActionInverse(
            month: "2026-07",
            legs: legs,
            previousBudgeted: ["groceries": 50_000, "dining": 0]
        ))
        try #expect(inverse.codableRoundTrip() == inverse)
    }

    @Test func kindsPersistAsDistinctDiscriminators() throws {
        let assign = BudgetActionInverse.assign(AssignBudgetAction(
            month: "2026-07",
            categoryID: "groceries",
            before: 0,
            after: 1
        ))
        let move = BudgetActionInverse.move(MoveBudgetActionInverse(
            month: "2026-07",
            legs: [BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: nil, amount: 1)],
            previousBudgeted: ["groceries": 1]
        ))
        let assignJSON = try JSONEncoder().encode(assign)
        let moveJSON = try JSONEncoder().encode(move)
        #expect(assignJSON != moveJSON)
        #expect(try JSONDecoder().decode(BudgetActionInverse.self, from: assignJSON) == assign)
        #expect(try JSONDecoder().decode(BudgetActionInverse.self, from: moveJSON) == move)
    }
}

private extension Encodable where Self: Decodable {
    func codableRoundTrip() throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(self))
    }
}
