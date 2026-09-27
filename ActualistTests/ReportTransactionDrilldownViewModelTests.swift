import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Report Transaction Drilldown View Model")
struct ReportTransactionDrilldownViewModelTests {
    @Test func preCancelledLoadDoesNotCallRepository() async {
        let model = ReportTransactionDrilldownViewModel()
        let repository = ControlledReportDrilldownRepository()
        let start = TestLatch()
        let task = Task {
            await start.wait()
            await model.load(
                budgetID: "budget",
                request: reportDrilldownRequest(day: "2026-01-01"),
                repository: repository,
                privacyModeEnabled: false
            )
        }

        task.cancel()
        start.trip()
        await task.value

        #expect(repository.requested.isEmpty)
        #expect(model.snapshot == nil)
    }

    @Test func retryRejectsCancellationInsensitiveOldSuccessAfterNewSuccess() async {
        let request = reportDrilldownRequest(day: "2026-01-01")
        let oldSnapshot = reportDrilldownSnapshot(id: "old", request: request)
        let newSnapshot = reportDrilldownSnapshot(id: "new", request: request)
        let started = TestLatch()
        let release = TestLatch()
        let completed = TestLatch()
        let repository = ControlledReportDrilldownRepository(plans: [
            .suspendedSuccess(oldSnapshot, started: started, release: release, completed: completed),
            .success(newSnapshot),
        ])
        let model = ReportTransactionDrilldownViewModel()

        let oldLoad = Task {
            await model.load(
                budgetID: "budget",
                request: request,
                repository: repository,
                privacyModeEnabled: false
            )
        }
        await started.wait()
        model.retry()
        oldLoad.cancel()
        await model.load(
            budgetID: "budget",
            request: request,
            repository: repository,
            privacyModeEnabled: false
        )

        release.trip()
        await completed.wait()
        await oldLoad.value

        #expect(model.snapshot?.loaded.transactions.first?.id == "new")
        #expect(model.state == .loaded)
    }

    @Test func newerRequestRejectsLateOldFailure() async {
        let firstRequest = reportDrilldownRequest(day: "2026-01-01")
        let nextRequest = reportDrilldownRequest(day: "2026-01-02")
        let nextSnapshot = reportDrilldownSnapshot(id: "new", request: nextRequest)
        let started = TestLatch()
        let release = TestLatch()
        let completed = TestLatch()
        let repository = ControlledReportDrilldownRepository(plans: [
            .suspendedFailure(started: started, release: release, completed: completed),
            .success(nextSnapshot),
        ])
        let model = ReportTransactionDrilldownViewModel()

        let oldLoad = Task {
            await model.load(
                budgetID: "budget",
                request: firstRequest,
                repository: repository,
                privacyModeEnabled: false
            )
        }
        await started.wait()
        await model.load(
            budgetID: "budget",
            request: nextRequest,
            repository: repository,
            privacyModeEnabled: false
        )

        release.trip()
        await completed.wait()
        await oldLoad.value

        #expect(model.snapshot?.request == nextRequest)
        #expect(model.state == .loaded)
    }

    @Test func sameBudgetNewSessionRejectsOldSuccessAfterCompletion() async {
        let request = reportDrilldownRequest(day: "2026-01-01")
        let oldSnapshot = reportDrilldownSnapshot(id: "old", request: request)
        let newSnapshot = reportDrilldownSnapshot(id: "new", request: request)
        let started = TestLatch()
        let release = TestLatch()
        let completed = TestLatch()
        let repository = ControlledReportDrilldownRepository(plans: [
            .suspendedSuccess(oldSnapshot, started: started, release: release, completed: completed),
            .success(newSnapshot),
        ])
        let model = ReportTransactionDrilldownViewModel()

        let oldLoad = Task {
            await model.load(
                budgetID: "budget",
                request: request,
                repository: repository,
                privacyModeEnabled: false
            )
        }
        await started.wait()
        repository.sessionGenerationByBudget["budget"] = 1
        await model.load(
            budgetID: "budget",
            request: request,
            repository: repository,
            privacyModeEnabled: false
        )

        release.trip()
        await completed.wait()
        await oldLoad.value

        #expect(model.snapshot?.loaded.transactions.first?.id == "new")
        #expect(model.state == .loaded)
    }

    @Test func budgetReplacementRejectsOldSuccessAfterCompletion() async {
        let request = reportDrilldownRequest(day: "2026-01-01")
        let oldSnapshot = reportDrilldownSnapshot(id: "old", request: request)
        let newSnapshot = reportDrilldownSnapshot(id: "new", request: request)
        let started = TestLatch()
        let release = TestLatch()
        let completed = TestLatch()
        let repository = ControlledReportDrilldownRepository(plans: [
            .suspendedSuccess(oldSnapshot, started: started, release: release, completed: completed),
            .success(newSnapshot),
        ])
        let model = ReportTransactionDrilldownViewModel()

        let oldLoad = Task {
            await model.load(
                budgetID: "old-budget",
                request: request,
                repository: repository,
                privacyModeEnabled: false
            )
        }
        await started.wait()
        await model.load(
            budgetID: "new-budget",
            request: request,
            repository: repository,
            privacyModeEnabled: false
        )

        release.trip()
        await completed.wait()
        await oldLoad.value

        #expect(repository.requested.map { $0.budgetID } == ["old-budget", "new-budget"])
        #expect(model.snapshot?.loaded.transactions.first?.id == "new")
        #expect(model.state == .loaded)
    }

    @Test func loadIdentityIncludesFullScopeNotOnlyQuerySignature() {
        let query = TransactionFeedQuery(conditions: [
            .account(.oneOf(["checking"])),
        ])
        let requestID = UUID()
        let spending = ReportDrilldownLoadIdentity(
            request: TransactionDrilldownRequest(scope: .spending, query: query),
            requestID: requestID,
            budgetID: "budget",
            sessionGeneration: 1
        )
        let account = ReportDrilldownLoadIdentity(
            request: TransactionDrilldownRequest(scope: .account("checking"), query: query),
            requestID: requestID,
            budgetID: "budget",
            sessionGeneration: 1
        )

        #expect(spending != account)
    }

    @Test func projectionShowsParentContributingChildAndSiblingContextAsPhysicalRows() throws {
        let request = reportDrilldownRequest(day: "2026-01-01")
        let contributingChild = reportTransaction(
            id: "matching-child",
            amount: -400,
            category: "groceries",
            isChild: true,
            parentID: "split-parent"
        )
        let siblingContext = reportTransaction(
            id: "sibling-context",
            amount: -600,
            category: "utilities",
            isChild: true,
            parentID: "split-parent"
        )
        let parent = reportTransaction(
            id: "split-parent",
            amount: -1_000,
            category: nil,
            subtransactions: [contributingChild, siblingContext],
            isParent: true
        )
        let loaded = LoadedAccountTransactions(
            transactions: [parent],
            balance: nil,
            accountNames: ["checking": "Checking"],
            categoryNames: ["groceries": "Groceries", "utilities": "Utilities"],
            payeeNames: [:],
            transferPayeeIDs: [],
            reachedEnd: true
        )
        let snapshot = ReportTransactionDrilldownSnapshot(
            request: request,
            loaded: loaded,
            contributingTransactionIDs: ["matching-child"]
        )

        let state = ReportTransactionDrilldownProjection(
            snapshot: snapshot,
            privacyModeEnabled: false
        ).displayState
        let rows = try #require(state.groups.first).rows

        #expect(rows.map(\.id) == ["split-parent", "matching-child", "sibling-context"])
        #expect(rows.map(\.role) == [.context, .contributor, .context])
        #expect(rows[0].relationship == .root)
        #expect(rows[1].relationship == .splitChild(parentID: "split-parent"))
        #expect(rows[2].relationship == .splitChild(parentID: "split-parent"))
        #expect(state.contributingCount == 1)
    }
}

@MainActor
private final class ControlledReportDrilldownRepository: ReportsRepositoryProtocol {
    enum Plan {
        case success(ReportTransactionDrilldownSnapshot)
        case suspendedSuccess(
            ReportTransactionDrilldownSnapshot,
            started: TestLatch,
            release: TestLatch,
            completed: TestLatch
        )
        case suspendedFailure(started: TestLatch, release: TestLatch, completed: TestLatch)
    }

    var plans: [Plan]
    var requested: [(budgetID: String, request: TransactionDrilldownRequest)] = []
    var sessionGenerationByBudget: [String: Int] = [:]

    init(plans: [Plan] = []) {
        self.plans = plans
    }

    func reportExplorerSessionIdentity(budgetID: String) -> ReportExplorerSessionIdentity {
        ReportExplorerSessionIdentity(
            budgetID: budgetID,
            generation: sessionGenerationByBudget[budgetID] ?? 0
        )
    }

    func cachedReportsDashboard(budgetID: String, range: ReportDateRange) -> ReportsDashboardSnapshot? {
        nil
    }

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot {
        throw ReportDrilldownTestError.failed
    }

    func reportExplorerSnapshot(
        budgetID: String,
        query: ReportExplorerQuery
    ) async throws -> ReportExplorerSnapshot {
        throw ReportDrilldownTestError.failed
    }

    func reportTransactionDrilldown(
        budgetID: String,
        request: TransactionDrilldownRequest
    ) async throws -> ReportTransactionDrilldownSnapshot {
        requested.append((budgetID, request))
        guard !plans.isEmpty else { throw ReportDrilldownTestError.failed }
        let plan = plans.removeFirst()
        switch plan {
        case .success(let snapshot):
            return snapshot
        case .suspendedSuccess(let snapshot, let started, let release, let completed):
            started.trip()
            await release.wait()
            completed.trip()
            return snapshot
        case .suspendedFailure(let started, let release, let completed):
            started.trip()
            await release.wait()
            completed.trip()
            throw ReportDrilldownTestError.failed
        }
    }
}

private enum ReportDrilldownTestError: Error {
    case failed
}

private func reportDrilldownRequest(day: String) -> TransactionDrilldownRequest {
    guard let queryDay = TransactionQueryDay(rawValue: day) else {
        preconditionFailure("Test day must be a normalized calendar day")
    }
    return TransactionDrilldownRequest(
        scope: .spending,
        query: TransactionFeedQuery(conditions: [
            .date(TransactionQueryDateCondition(operation: .isOn, day: queryDay)),
        ])
    )
}

private func reportDrilldownSnapshot(
    id: String,
    request: TransactionDrilldownRequest
) -> ReportTransactionDrilldownSnapshot {
    let transaction = reportTransaction(id: id, amount: -100, category: "groceries")
    return ReportTransactionDrilldownSnapshot(
        request: request,
        loaded: LoadedAccountTransactions(
            transactions: [transaction],
            balance: nil,
            categoryNames: ["groceries": "Groceries"],
            payeeNames: [:],
            transferPayeeIDs: [],
            reachedEnd: true
        ),
        contributingTransactionIDs: [id]
    )
}

private func reportTransaction(
    id: String,
    amount: Int,
    category: String?,
    subtransactions: [ActualTransaction] = [],
    isParent: Bool = false,
    isChild: Bool = false,
    parentID: String? = nil
) -> ActualTransaction {
    ActualTransaction(
        id: id,
        account: "checking",
        date: "2026-01-01",
        amount: amount,
        payee: nil,
        payeeName: nil,
        importedPayee: "Test Payee",
        category: category,
        notes: nil,
        cleared: .bool(false),
        subtransactions: subtransactions,
        isParent: isParent,
        isChild: isChild,
        parentID: parentID
    )
}
