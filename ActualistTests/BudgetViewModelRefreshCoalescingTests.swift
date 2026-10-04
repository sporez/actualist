import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetViewModelRefreshCoalescingTests {
    /// Starts `count` refresh requests while one read is blocked, commits a newer
    /// month snapshot after that read began, then releases the read.
    private func refresh(requests count: Int) async -> (BudgetViewModel, BudgetViewportTestRepository) {
        let repository = BudgetViewportTestRepository()
        await repository.setReadsSnapshotAtStart(true)
        await repository.set(BudgetViewportFixtures.loaded("2026-07", budgeted: 100))
        let model = BudgetViewModel()
        await model.selectMonth("2026-07", budgetID: "budget", repository: repository)
        #expect(await repository.budgetMonthReadCount(for: "2026-07") == 1)

        await repository.block("2026-07")
        let requests = (0..<count).map { _ in
            Task { await model.refreshSelectedMonth(budgetID: "budget", repository: repository) }
        }
        await repository.waitUntilReadBlocked("2026-07")
        #expect(model.isLoading)
        // Committed after the in-flight read began, so only a later read sees it.
        await repository.set(BudgetViewportFixtures.loaded("2026-07", budgeted: 200))

        await repository.release("2026-07")
        for request in requests { await request.value }
        return (model, repository)
    }

    @Test func requestArrivingMidLoadTriggersOneTrailingReadWithTheNewerState() async {
        let (model, repository) = await refresh(requests: 2)

        // One initial read, the in-flight refresh read, and one trailing read.
        #expect(await repository.budgetMonthReadCount(for: "2026-07") == 3)
        #expect(model.budgetMonth?.totalBudgeted == 200)
        #expect(!model.isLoading)
        #expect(model.selectedMonth == "2026-07")
    }

    @Test func manyRequestsDuringOneLoadShareASingleTrailingRead() async {
        let (model, repository) = await refresh(requests: 5)

        #expect(await repository.budgetMonthReadCount(for: "2026-07") == 3)
        #expect(model.budgetMonth?.totalBudgeted == 200)
        #expect(!model.isLoading)
    }

    @Test func aLoneRefreshRequestReadsOnce() async {
        let (model, repository) = await refresh(requests: 1)

        #expect(await repository.budgetMonthReadCount(for: "2026-07") == 2)
        // The only read began before the newer commit.
        #expect(model.budgetMonth?.totalBudgeted == 100)
    }
}
