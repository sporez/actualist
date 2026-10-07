import Foundation
import Testing
@testable import Actualist

@MainActor
struct HistoryViewModelStaleLoadTests {
    @Test func olderLoadArrivingLateDoesNotOverwriteANewerLoad() async {
        let gate = TestLatch()
        let firstEntered = TestLatch()
        let repository = BudgetViewportTestRepository()
        await repository.setRecentActionsHandler { read in
            if read == 1 {
                firstEntered.trip()
                await gate.wait()
                return [Self.record(id: "old")]
            }
            return [Self.record(id: "new")]
        }
        let model = HistoryViewModel()
        let older = Task { await model.load(budgetID: "budget", repository: repository) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            firstEntered.trip()
            gate.trip()
        }
        defer { deadline.cancel(); older.cancel(); gate.trip() }
        await firstEntered.wait()

        await model.load(budgetID: "budget", repository: repository)
        #expect(model.rows.map(\.id) == ["new"])

        gate.trip()
        await older.value

        // The older response has now completed; it must not replace newer rows.
        #expect(model.rows.map(\.id) == ["new"])
        #expect(model.records.map(\.id) == ["new"])
        #expect(model.loadState == .loaded)
    }

    private nonisolated static func record(id: String) -> BudgetActionRecord {
        let assign = AssignBudgetAction(month: "2026-07", categoryID: "groceries", before: 0, after: 1_000)
        return BudgetActionRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .assign,
            status: .applied,
            month: "2026-07",
            summary: .assign(assign),
            inverse: .assign(assign),
            affectedCategoryIDs: ["groceries"],
            forwardTimestampStart: nil,
            forwardTimestampEnd: nil,
            source: .ui
        )
    }
}
