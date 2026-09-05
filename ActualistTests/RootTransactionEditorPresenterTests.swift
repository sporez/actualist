import Testing
@testable import Actualist

@MainActor
struct RootTransactionEditorPresenterTests {
    private let context = TransactionEditorSession.Context(budgetID: "budget", serverURL: "")

    @Test func openingRetainsShortcutInputAndRefusesReplacement() throws {
        let presenter = RootTransactionEditorPresenter()
        let prefill = ShortcutEditorPrefill(accountID: "checking", amountMinorUnits: 1234, payeeName: "Coffee", categoryName: "Dining", notes: "Original")
        #expect(presenter.present(context: context, prefill: prefill))
        let session = try #require(presenter.presentation)
        session.model.notes = "Typed draft"
        session.model.isCleared = true
        #expect(!presenter.present(context: context))
        #expect(presenter.presentation === session)
        #expect(session.model.amountDigits == "1234")
        #expect(session.model.selectedAccountID == "checking")
        #expect(session.model.notes == "Typed draft")
        #expect(session.model.isCleared)
        presenter.presentation = nil
        #expect(presenter.present(context: context))
        #expect(presenter.presentation?.id != session.id)
    }

    @Test func invalidatedSessionCannotBecomeCurrentAgain() {
        let session = TransactionEditorSession(context: context)
        #expect(session.isCurrent(context))
        let wrongBudget = session.isCurrent(TransactionEditorSession.Context(budgetID: "other", serverURL: ""))
        let wrongConnection = session.isCurrent(TransactionEditorSession.Context(budgetID: "budget", serverURL: "other"))
        #expect(wrongBudget == false)
        #expect(wrongConnection == false)
        session.invalidate()
        #expect(!session.isCurrent(context))
    }
}

extension RootTransactionEditorPresenterTests {
    @Test func preparationRunsOnceAndRetainsCompleteSplitDraft() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let state = try support.makeAppState(for: bundle)
        let presenter = RootTransactionEditorPresenter()
        #expect(presenter.present(using: state, prefill: .init(accountID: "checking", amountMinorUnits: 1234, payeeName: "Coffee")))
        let session = try #require(presenter.presentation)
        await session.prepare(using: state)
        session.model.notes = "Retained notes"
        session.model.isCleared = true
        session.model.selectAccount(try #require(session.model.accounts.first { $0.id == "savings" }))
        session.model.beginSplit()
        let row = try #require(session.model.splitRows.first)
        session.model.setSplitAmount(rowID: row.id, value: "1234")
        let rows = session.model.splitRows
        let date = session.model.date
        await session.prepare(using: state)
        #expect(session.model.notes == "Retained notes")
        #expect(session.model.isCleared)
        #expect(session.model.selectedAccountID == "savings")
        #expect(session.model.splitRows == rows)
        #expect(session.model.date == date)
        #expect(await session.submit(using: state))
        #expect(await session.submit(using: state) == false)
        let stored = try await bundle.store.searchAccountTransactions(budgetID: "group-1", accountID: "savings", query: "Retained notes", limit: 50, offset: 0)
        #expect(stored.transactions.count == 1)
    }

    @Test func invalidatedEditorCannotSaveAndPendingShortcutIsNotConsumed() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let state = try support.makeAppState(for: bundle)
        let presenter = RootTransactionEditorPresenter()
        #expect(presenter.present(using: state, prefill: .init(accountID: "checking", amountMinorUnits: 1234, payeeName: "Coffee")))
        let session = try #require(presenter.presentation)
        await session.prepare(using: state)
        state.routeCoordinator.enqueue(.newTransaction(.init(notes: "Second request")))
        #expect(!presenter.consumeNewTransaction(using: state))
        #expect(state.routeCoordinator.pendingRoute != nil)
        session.invalidate()
        #expect(await session.submit(using: state) == false)
        #expect(session.model.amountDigits == "1234")
    }
}
