import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionFilterWorkflowTests {
    @Test func buildsDateAccountPayeeAndCategoryConditionsWithSelectedJoin() throws {
        var applied: ([TransactionQueryCondition], TransactionQueryJoin)?
        let workflow = TransactionFilterWorkflow(onApply: { applied = ($0, $1) })
        workflow.conditionsJoin = .or
        workflow.includesDate = true
        workflow.date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 18)))
        workflow.dateOperation = .isOnOrAfter
        workflow.toggleSelection("checking", in: .account)
        workflow.toggleSelection("market", in: .payee)
        workflow.toggleSelection("groceries", in: .category)

        #expect(workflow.apply())
        let conditions = try #require(applied?.0)
        #expect(applied?.1 == .or)
        #expect(conditions.contains(.date(TransactionQueryDateCondition(
            operation: .isOnOrAfter,
            day: try #require(TransactionQueryDay(rawValue: "2026-09-18"))
        ))))
        #expect(conditions.contains(.account(.oneOf(["checking"]))))
        #expect(conditions.contains(.payee(.oneOf(["market"]))))
        #expect(conditions.contains(.category(.oneOf(["groceries"]))))
    }

    @Test func authoringNullUsesOnlyScalarEqualsOrNotEquals() throws {
        var applied: [TransactionQueryCondition] = []
        let workflow = TransactionFilterWorkflow(onApply: { conditions, _ in applied = conditions })
        workflow.setNullSelection(.payee, isSelected: true)
        workflow.setNullSelection(.category, isSelected: true)

        #expect(workflow.operation(for: .payee) == .isEqual)
        #expect(workflow.operation(for: .category) == .isEqual)
        #expect(workflow.apply())
        #expect(applied.contains(.payee(.equals(nil))))
        #expect(applied.contains(.category(.equals(nil))))

        workflow.setOperation(.isNotEqual, for: .category)
        #expect(workflow.apply())
        #expect(applied.contains(.category(.doesNotEqual(nil))))
        #expect(!applied.contains(.category(.oneOf([nil]))))

        workflow.setOperation(.isOneOf, for: .category)
        #expect(!workflow.apply())
        #expect(workflow.includesUncategorized)
        #expect(workflow.validationMessage?.contains("Use “Is” or “Is not”") == true)
    }

    @Test func accountNullIsNotOfferedAsAnAuthoredCondition() {
        let workflow = TransactionFilterWorkflow()
        workflow.setNullSelection(.account, isSelected: true)
        #expect(workflow.apply())
        #expect(workflow.selectedAccountIDs.isEmpty)
    }

    @Test func mixedNullAndUnresolvableConditionsRemainReadableAndUnchanged() throws {
        let oldDate = try #require(TransactionQueryDay(rawValue: "2026-09-01"))
        let conditions: [TransactionQueryCondition] = [
            .account(.oneOf(["closed-account", "missing-account"])),
            .account(.doesNotEqual("legacy-account")),
            .account(.equals(nil)),
            .date(TransactionQueryDateCondition(operation: .isBefore, day: try #require(TransactionQueryDay(rawValue: "2026-10-01")))),
            .date(TransactionQueryDateCondition(operation: .isAfter, day: oldDate)),
            .category(.oneOf([nil, "retired-category"])),
            .payee(.equals(nil)),
            .transfer(false),
        ]
        let workflow = TransactionFilterWorkflow(conditions: conditions, join: .or)

        #expect(workflow.selectedAccountIDs == ["closed-account", "missing-account"])
        #expect(workflow.selectionSummary(for: .account).contains("Unavailable (missing-account)"))
        #expect(workflow.selectionSummary(for: .payee) == "No payee")
        #expect(workflow.selectionSummary(for: .category) == "Any")
        #expect(workflow.preservedConditionSummaries.count == 5)
        #expect(workflow.preservedConditionSummaries.contains { $0.contains("No category") })
        #expect(workflow.preservedConditionSummaries.contains { $0.contains("No account") })

        var applied: [TransactionQueryCondition] = []
        workflow.configure(conditions: conditions, join: .or, onApply: { conditions, _ in applied = conditions })
        #expect(workflow.apply())
        #expect(TransactionFeedQuery(conditionsJoin: .or, conditions: applied)
            == TransactionFeedQuery(conditionsJoin: .or, conditions: conditions))
        #expect(workflow.conditionsJoin == .or)
    }

    @Test func invalidScalarDraftCannotApplyOrLoseAnySelectedID() {
        var applied = false
        let workflow = TransactionFilterWorkflow(onApply: { _, _ in applied = true })
        workflow.setOperation(.isEqual, for: .account)
        workflow.toggleSelection("checking", in: .account)
        workflow.toggleSelection("savings", in: .account)

        #expect(!workflow.apply())
        #expect(workflow.validationMessage == "Choose one account for this condition.")
        #expect(workflow.selectedAccountIDs == ["checking", "savings"])
        #expect(!applied)
    }

    @Test func emptyOperandsArePreservedInsteadOfBroadeningTheQuery() {
        var applied: [TransactionQueryCondition] = []
        let emptyAccount = TransactionQueryCondition.account(.oneOf([" "]))
        let emptyPayee = TransactionQueryCondition.payee(.equals("\n"))
        let workflow = TransactionFilterWorkflow(
            conditions: [emptyAccount, emptyPayee],
            onApply: { conditions, _ in applied = conditions }
        )

        #expect(workflow.preservedConditionSummaries.count == 2)
        #expect(workflow.apply())
        #expect(Set(applied) == Set([emptyAccount, emptyPayee]))
    }

    @Test func loadedClosedAccountOptionsRemainAvailableForSpendingFilters() async {
        let workflow = TransactionFilterWorkflow()
        let closed = ActualAccount(id: "closed-id", name: "Old Account", offbudget: false, closed: true)

        await workflow.loadOptions(
            budgetID: "budget",
            repository: AccountTransactionsRecordingRepository(),
            availableAccounts: [closed]
        ).value

        #expect(workflow.selectionSummary(for: .account) == "Any")
        #expect(workflow.optionsForSelection(in: .account) == [
            TransactionFilterOption(id: "closed-id", title: "Old Account (Closed)")
        ])
    }

    @Test func clearIntentAppliesEmptyConditionsAndAndJoin() {
        var applied: ([TransactionQueryCondition], TransactionQueryJoin)?
        let workflow = TransactionFilterWorkflow(
            conditions: [.account(.equals("checking")), .transfer(false)],
            join: .or,
            onApply: { applied = ($0, $1) }
        )

        #expect(workflow.clearAndApply())
        #expect(applied?.0.isEmpty == true)
        #expect(applied?.1 == .and)
    }

    @Test func sameStructuredQueryAppendsItsNextPageButRejectsAChangedCondition() {
        let query = TransactionFeedQuery(
            status: .cleared,
            text: "market",
            conditions: [.category(.equals("groceries"))]
        )
        let nextQuery = query.replacingConditions(join: .and, conditions: [.category(.equals("utilities"))])
        let current = page(id: "first", query: query, nextOffset: 1)
        let sameQueryPage = page(id: "second", query: query, nextOffset: 2)
        let changedQueryPage = page(id: "stale", query: nextQuery, nextOffset: 2)

        #expect(current.appendingPage(sameQueryPage).transactions.compactMap(\.id) == ["first", "second"])
        #expect(current.appendingPage(changedQueryPage) == current)
    }

    @Test func queryReadSessionRejectsACompletionAfterBudgetChange() {
        let session = TransactionFeedReadSession()
        let query = TransactionFeedQuery(conditions: [.payee(.equals("market"))])
        let oldIdentity = TransactionFeedReadSession.Identity(
            budgetID: "old-budget", scope: .spending, query: query
        )
        let requestID = session.beginLocalRead(oldIdentity, hasCachedPage: false)
        let newIdentity = TransactionFeedReadSession.Identity(
            budgetID: "new-budget", scope: .spending, query: query
        )

        session.activate(newIdentity)
        session.finish(requestID, identity: oldIdentity)

        #expect(session.state.identity == newIdentity)
        #expect(session.state.phase == .idle)
        #expect(session.state.searchPage == nil)
    }

    @Test func applyingStructuredConditionsPreservesOuterStatusAndSearchIdentity() async throws {
        let repository = AccountTransactionsRecordingRepository()
        let model = AccountTransactionsViewModel(scope: .spending, searchDelay: .zero)
        model.searchText = " market "
        await model.selectFilter(.cleared, budgetID: "budget", repository: repository)
        let conditions: [TransactionQueryCondition] = [.category(.equals("groceries"))]
        var applied: ([TransactionQueryCondition], TransactionQueryJoin)?
        let workflow = TransactionFilterWorkflow(onApply: { applied = ($0, $1) })
        workflow.configure(conditions: conditions, join: .or, onApply: { applied = ($0, $1) })

        #expect(workflow.apply())
        let command = try #require(applied)
        await model.applyStructuredConditions(command.0, join: command.1, budgetID: "budget", repository: repository)

        #expect(model.activeFeedQuery.status == .cleared)
        #expect(model.activeFeedQuery.text == "market")
        #expect(model.activeFeedQuery.conditions == conditions)
        #expect(model.activeFeedQuery.conditionsJoin == .or)
    }

    @Test(arguments: [false, true])
    func dismissedOptionLoadCannotPublishLateSuccessOrCancellationError(fails: Bool) async throws {
        let repository = HeldTransactionOptionsRepository()
        let workflow = TransactionFilterWorkflow(conditions: [.payee(.equals("old-payee"))])
        let load = workflow.loadOptions(budgetID: "budget", repository: repository)
        try await repository.waitForOptionsRequest(1, tasks: [load])

        workflow.cancelLoading()
        if fails {
            repository.failOptionsRequest(1, error: CancellationError())
        } else {
            repository.finishOptionsRequest(1, with: options(payeeID: "late-payee"))
        }
        await load.value

        #expect(workflow.optionsForSelection(in: .payee).map(\.id) == ["old-payee"])
        #expect(workflow.selectionSummary(for: .payee) == "Unavailable (old-payee)")
        #expect(workflow.errorMessage == nil)
        #expect(!workflow.isLoading)
    }

    @Test func sameBudgetSupersedingOptionLoadRejectsLateOlderResult() async throws {
        let repository = HeldTransactionOptionsRepository()
        let workflow = TransactionFilterWorkflow(conditions: [.account(.equals("old-account"))])
        let first = workflow.loadOptions(budgetID: "budget", repository: repository)
        try await repository.waitForOptionsRequest(1, tasks: [first])

        workflow.configure(conditions: [.account(.equals("new-account"))], join: .or, onApply: { _, _ in })
        let second = workflow.loadOptions(budgetID: "budget", repository: repository)
        try await repository.waitForOptionsRequest(2, tasks: [first, second])
        repository.finishOptionsRequest(2, with: options(accountID: "new-account"))
        await second.value
        repository.finishOptionsRequest(1, with: options(accountID: "stale-account"))
        await first.value

        #expect(workflow.accounts.map(\.id) == ["new-account"])
        #expect(workflow.selectionSummary(for: .account) == "New Account")
        #expect(workflow.errorMessage == nil)
        #expect(!workflow.isLoading)
    }

    @Test func optionLoadFailureKeepsSelectionsAndRetryIsOwnedUntilCompletion() async throws {
        let repository = HeldTransactionOptionsRepository()
        let workflow = TransactionFilterWorkflow(conditions: [.category(.equals("missing-category"))])
        let first = workflow.loadOptions(budgetID: "budget", repository: repository)
        try await repository.waitForOptionsRequest(1, tasks: [first])
        repository.failOptionsRequest(1, error: FeedTestError("options unavailable"))
        await first.value

        #expect(workflow.errorMessage?.contains("options unavailable") == true)
        #expect(workflow.selectionSummary(for: .category) == "Unavailable (missing-category)")

        let retry = workflow.loadOptions(
            budgetID: "budget",
            repository: repository,
            availableAccounts: []
        )
        try await repository.waitForOptionsRequest(2, tasks: [retry])
        repository.finishOptionsRequest(2, with: options(categoryID: "groceries"))
        await retry.value

        #expect(workflow.errorMessage == nil)
        #expect(workflow.selectionSummary(for: .category) == "Unavailable (missing-category)")
        #expect(workflow.optionsForSelection(in: .category).map(\.id) == ["groceries", "missing-category"])
    }

    @Test func reconfigurationClearsPriorBudgetOptionsAndSearch() async throws {
        let repository = HeldTransactionOptionsRepository()
        let workflow = TransactionFilterWorkflow()
        let load = workflow.loadOptions(budgetID: "old-budget", repository: repository)
        try await repository.waitForOptionsRequest(1, tasks: [load])
        repository.finishOptionsRequest(1, with: options(accountID: "old-account"))
        await load.value
        workflow.optionSearchText = "New"
        #expect(workflow.visibleOptions(in: .account).map(\.id) == ["old-account"])

        workflow.configure(conditions: [.account(.equals("missing"))], join: .and, onApply: { _, _ in })
        #expect(workflow.optionSearchText.isEmpty)
        #expect(workflow.accounts.isEmpty)
        #expect(workflow.visibleOptions(in: .account) == [
            TransactionFilterOption(id: "missing", title: "Unavailable (missing)", isUnavailable: true)
        ])
        workflow.optionSearchText = "No match"
        #expect(workflow.visibleOptions(in: .account).isEmpty)
    }

    @Test func cancelledCallerCannotSupersedeTheCurrentOptionLoad() async throws {
        let repository = HeldTransactionOptionsRepository()
        let workflow = TransactionFilterWorkflow()
        let current = workflow.loadOptions(budgetID: "budget", repository: repository)
        try await repository.waitForOptionsRequest(1, tasks: [current])
        let mayStart = TestLatch()
        let obsolete = Task { @MainActor in
            await mayStart.wait()
            await workflow.loadOptions(budgetID: "budget", repository: repository).value
        }
        obsolete.cancel()
        mayStart.trip()
        await obsolete.value
        #expect(repository.optionsRequestCount == 1)
        #expect(workflow.isLoading)
        repository.finishOptionsRequest(1, with: options(accountID: "current"))
        await current.value
        #expect(workflow.accounts.map(\.id) == ["current"])
    }

    private func options(
        accountID: String? = nil,
        payeeID: String? = nil,
        categoryID: String? = nil
    ) -> TransactionEditorOptions {
        TransactionEditorOptions(
            accounts: accountID.map { [ActualAccount(id: $0, name: "New Account", offbudget: false, closed: false)] } ?? [],
            categories: categoryID.map { [ActualCategory(id: $0, name: "Groceries", isIncome: false, hidden: false, groupID: nil)] } ?? [],
            categoryGroups: [],
            payees: payeeID.map { [ActualPayee(id: $0, name: "Late Payee", category: nil, transferAccount: nil)] } ?? []
        )
    }

    private func page(id: String, query: TransactionFeedQuery, nextOffset: Int) -> LoadedAccountTransactions {
        LoadedAccountTransactions(
            transactions: [ActualTransaction(
                id: id, account: "checking", date: "2026-09-01", amount: -100,
                payee: nil, payeeName: nil, importedPayee: nil, category: nil, notes: nil,
                cleared: nil
            )],
            balance: nil,
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: [],
            reachedEnd: false,
            nextOffset: nextOffset,
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: 2,
                querySignature: query.signature,
                matchingTransactionIDs: [id],
                contributingTransactionIDs: [id],
                attachedContextTransactionIDs: []
            )
        )
    }
}

@MainActor
private final class HeldTransactionOptionsRepository: AccountTransactionsRecordingRepository {
    private(set) var optionsRequestCount = 0
    private var requestStarted: [Int: TestLatch] = [:]
    private var requestContinuations: [Int: CheckedContinuation<TransactionEditorOptions, any Error>] = [:]
    private var isClosed = false

    override func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        guard !isClosed else { throw CancellationError() }
        optionsRequestCount += 1
        let request = optionsRequestCount
        // Ignore cancellation intentionally, then release and await the obsolete load.
        return try await withCheckedThrowingContinuation {
            requestContinuations[request] = $0
            requestStarted[request]?.trip()
        }
    }

    func waitForOptionsRequest(_ request: Int, tasks: [Task<Void, Never>]) async throws {
        if optionsRequestCount >= request { return }
        let latch = requestStarted[request] ?? TestLatch()
        requestStarted[request] = latch
        do {
            try await withTimeLimit(.seconds(10), timeoutError: FeedTestError("Filter options request did not start")) {
                try await withTaskCancellationHandler {
                    await latch.wait()
                    try Task.checkCancellation()
                } onCancel: {
                    latch.trip()
                }
            }
        } catch {
            isClosed = true
            tasks.forEach { $0.cancel() }
            let pending = Array(requestContinuations.values)
            requestContinuations.removeAll()
            pending.forEach { $0.resume(throwing: CancellationError()) }
            for task in tasks { await task.value }
            throw error
        }
    }

    func finishOptionsRequest(_ request: Int, with options: TransactionEditorOptions) {
        requestContinuations.removeValue(forKey: request)?.resume(returning: options)
    }

    func failOptionsRequest(_ request: Int, error: any Error) {
        requestContinuations.removeValue(forKey: request)?.resume(throwing: error)
    }
}
