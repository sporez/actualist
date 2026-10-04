import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetViewModelRefreshCoalescingTests {
    @Test func concurrentRefreshRequestsShareOneInFlightLoad() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-07"))
        let model = BudgetViewModel()
        await model.selectMonth("2026-07", budgetID: "budget", repository: repository)
        #expect(await repository.budgetMonthReadCount(for: "2026-07") == 1)

        await repository.block("2026-07")
        let requests = (0..<5).map { _ in
            Task { await model.refreshSelectedMonth(budgetID: "budget", repository: repository) }
        }
        defer {
            requests.forEach { $0.cancel() }
            Task { await repository.release("2026-07") }
        }
        await repository.waitUntilReadBlocked("2026-07")
        #expect(model.isLoading)

        await repository.release("2026-07")
        for request in requests { await request.value }

        // One initial read plus a single shared refresh read.
        #expect(await repository.budgetMonthReadCount(for: "2026-07") == 2)
        #expect(!model.isLoading)
        #expect(model.selectedMonth == "2026-07")
    }
}
