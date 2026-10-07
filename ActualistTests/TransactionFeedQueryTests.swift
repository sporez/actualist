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
        let excludesTransfers = TransactionQueryCondition.transfer(false)

        let first = TransactionFeedQuery(
            status: .cleared,
            text: "  market  ",
            conditionsJoin: .or,
            conditions: [excludesTransfers, categories, date, categories, excludesTransfers]
        )
        let second = TransactionFeedQuery(
            status: .cleared,
            text: "market",
            conditionsJoin: .or,
            conditions: [date, excludesTransfers, categories]
        )

        #expect(first == second)
        #expect(first.signature == second.signature)
        #expect(first.text == "market")
        #expect(first.conditions == [categories, date, excludesTransfers])
        guard case .category(let ids) = first.conditions.first else {
            Issue.record("Expected canonical category condition first")
            return
        }
        #expect(ids.values == [nil, "groceries", "utilities"])
        #expect(first.conditions.last == excludesTransfers)
    }

    @Test func transferBooleanParticipatesInQueryIdentity() {
        let transfers = TransactionFeedQuery(conditions: [.transfer(true)])
        let nonTransfers = TransactionFeedQuery(conditions: [.transfer(false)])

        #expect(transfers != nonTransfers)
        #expect(transfers.signature != nonTransfers.signature)
        #expect(transfers.signature.stableSortKey.contains("transfer|true"))
        #expect(nonTransfers.signature.stableSortKey.contains("transfer|false"))
    }

    @Test func blankIDOperandsAreRemovedWithoutErasingExplicitNull() {
        #expect(TransactionQueryIDCondition.equals(nil).values == [nil])
        #expect(TransactionQueryIDCondition.equals("  ").values.isEmpty)
        #expect(TransactionQueryIDCondition.doesNotEqual("\n").values.isEmpty)
        #expect(TransactionQueryIDCondition.oneOf([" ", nil, " market "]).values == [nil, "market"])
        #expect(TransactionQueryIDCondition.notOneOf(["", "  "]).values.isEmpty)
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
            nextOffset: 1,
            matchingIDs: ["current"]
        )
        let older = loadedPage(
            id: "older",
            signature: TransactionFeedQuery(status: .uncleared).signature,
            nextOffset: 2,
            matchingIDs: ["older"]
        )

        #expect(current.appendingPage(older) == current)
    }

    @Test func pageAppendRemovesIDsFromContextWhenALaterPageMatchesThem() {
        let signature = TransactionFeedQuery(text: "shared").signature
        let current = loadedPage(
            id: "parent",
            signature: signature,
            nextOffset: 1,
            matchingIDs: ["parent"],
            contextIDs: ["child"]
        )
        let older = loadedPage(
            id: "child",
            signature: signature,
            nextOffset: 2,
            matchingIDs: ["child"]
        )

        let merged = current.appendingPage(older)

        #expect(merged.matchingTransactionIDs == ["parent", "child"])
        #expect(merged.attachedContextTransactionIDs?.isEmpty == true)
        #expect(merged.totalMatchCount == 2)
    }

    private func loadedPage(
        id: String,
        signature: TransactionQuerySignature,
        nextOffset: Int,
        matchingIDs: Set<String>,
        contextIDs: Set<String> = []
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
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: 2,
                querySignature: signature,
                matchingTransactionIDs: matchingIDs,
                contributingTransactionIDs: matchingIDs,
                attachedContextTransactionIDs: contextIDs
            )
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

@MainActor
struct TransactionRepositoryTypedQueryCompatibilityTests {
    @Test func legacyOnlyConformerCannotFabricateTypedQueryMetadata() async throws {
        let repository = RecordingTransactionRepository()
        let query = TransactionFeedQuery(status: .cleared, text: "market")
        let legacyPage = try await repository.searchSpendingTransactions(
            budgetID: "budget",
            query: "market",
            limit: 50,
            offset: 0,
            statusFilter: .cleared
        )

        #expect(legacyPage.queryMetadata == nil)
        #expect(repository.cachedTransactions(
            budgetID: "budget",
            scope: .spending,
            query: query
        ) == nil)
        await #expect(throws: TransactionQueryCapabilityError.unavailable) {
            try await repository.refreshTransactions(
                budgetID: "budget",
                scope: .spending,
                query: query
            )
        }
        await #expect(throws: TransactionQueryCapabilityError.unavailable) {
            try await repository.loadOlderTransactions(
                budgetID: "budget",
                scope: .spending,
                query: query
            )
        }
        await #expect(throws: TransactionQueryCapabilityError.unavailable) {
            _ = try await repository.transactionPage(
                budgetID: "budget",
                scope: .spending,
                query: query,
                limit: 50,
                offset: 0
            )
        }
    }
}
