import Testing
@testable import Actualist

struct TransactionFeedQueryTests {
    @Test func normalizesTextIDsAndConditionOrderIntoOneSemanticSignature() throws {
        let day = try #require(TransactionQueryDay(rawValue: "2026-09-07"))
        let date = TransactionQueryCondition.date(
            TransactionQueryDateCondition(operation: .isOnOrAfter, day: day)
        )
        let categories = TransactionQueryCondition.category(
            .oneOf([" utilities ", nil, "groceries", "utilities", ""])
        )

        let first = TransactionFeedQuery(
            status: .cleared,
            text: "  market  ",
            conditionsJoin: .or,
            conditions: [categories, date, categories]
        )
        let second = TransactionFeedQuery(
            status: .cleared,
            text: "market",
            conditionsJoin: .or,
            conditions: [date, categories]
        )

        #expect(first == second)
        #expect(first.signature == second.signature)
        #expect(first.text == "market")
        #expect(first.conditions.count == 2)
        guard case .category(let ids) = first.conditions.first else {
            Issue.record("Expected canonical category condition first")
            return
        }
        #expect(ids.values == [nil, "groceries", "utilities"])
    }

    @Test func queryReplacementKeepsTheOtherNormalizedIdentityFields() throws {
        let day = try #require(TransactionQueryDay(rawValue: "2026-09-09"))
        let condition = TransactionQueryCondition.date(
            TransactionQueryDateCondition(operation: .isApproximately, day: day)
        )
        let query = TransactionFeedQuery(
            status: .uncleared,
            text: "  ",
            conditionsJoin: .and,
            conditions: [condition]
        )

        let replaced = query.replacingStatus(.reconciled).replacingText(" needle ")

        #expect(query.text == nil)
        #expect(replaced.status == .reconciled)
        #expect(replaced.text == "needle")
        #expect(replaced.conditionsJoin == .and)
        #expect(replaced.conditions == [condition])
    }

    @Test func validatesGregorianTransactionDays() {
        #expect(TransactionQueryDay(rawValue: "2024-02-29")?.rawValue == "2024-02-29")
        #expect(TransactionQueryDay(rawValue: "2025-02-29") == nil)
        #expect(TransactionQueryDay(rawValue: "2026-9-07") == nil)
        #expect(TransactionQueryDay(rawValue: "2026-09-31") == nil)
    }

    @Test func pageAppendRejectsAnotherQuerySignature() {
        let current = loadedPage(
            id: "current",
            signature: TransactionFeedQuery(status: .cleared).signature,
            nextOffset: 1
        )
        let older = loadedPage(
            id: "older",
            signature: TransactionFeedQuery(status: .uncleared).signature,
            nextOffset: 2
        )

        #expect(current.appendingPage(older) == current)
    }

    private func loadedPage(
        id: String,
        signature: TransactionQuerySignature,
        nextOffset: Int
    ) -> LoadedAccountTransactions {
        LoadedAccountTransactions(
            transactions: [ActualTransaction(
                id: id,
                account: "checking",
                date: "2026-09-01",
                amount: -100,
                payee: nil,
                payeeName: nil,
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: nil
            )],
            balance: nil,
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: [],
            reachedEnd: false,
            nextOffset: nextOffset,
            querySignature: signature
        )
    }
}

@MainActor
struct TransactionFeedReadSessionQueryIdentityTests {
    @Test func structuredQueryChangeRejectsTheObsoleteCompletion() {
        let session = TransactionFeedReadSession()
        let firstQuery = TransactionFeedQuery(conditions: [.category(.equals("groceries"))])
        let first = TransactionFeedReadSession.Identity(
            budgetID: "budget",
            scope: .spending,
            query: firstQuery
        )
        let staleRequest = session.beginLocalRead(first, hasCachedPage: false)
        let current = TransactionFeedReadSession.Identity(
            budgetID: "budget",
            scope: .spending,
            query: TransactionFeedQuery(conditions: [.category(.equals("utilities"))])
        )

        session.activate(current)
        session.finish(staleRequest, identity: first)

        #expect(session.state.identity == current)
        #expect(session.state.phase == .idle)
        #expect(session.state.searchPage == nil)
    }

    @Test func scopeParticipatesInReadIdentity() {
        let query = TransactionFeedQuery(status: .cleared, text: "market")
        let account = TransactionFeedReadSession.Identity(
            budgetID: "budget",
            scope: .account("checking"),
            query: query
        )
        let spending = TransactionFeedReadSession.Identity(
            budgetID: "budget",
            scope: .spending,
            query: query
        )

        #expect(account != spending)
    }
}
