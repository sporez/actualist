import Foundation
@testable import Actualist

@MainActor
extension AccountTransactionsRecordingRepository {
    func cachedTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) -> LoadedAccountTransactions? {
        guard query.text == nil, !query.hasStructuredConditions else { return nil }
        let loaded: LoadedAccountTransactions? = switch scope {
        case .account(let accountID):
            cachedAccountTransactions(
                budgetID: budgetID,
                accountID: accountID,
                statusFilter: query.status
            )
        case .spending:
            cachedSpendingTransactions(budgetID: budgetID, statusFilter: query.status)
        }
        return loaded?.replacingFixtureQueryMetadata(for: query)
    }

    func refreshTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        guard query.text == nil, !query.hasStructuredConditions else {
            throw LocalFirstError.unsupportedWrite
        }
        switch scope {
        case .account(let accountID):
            try await refreshAccountTransactions(
                budgetID: budgetID,
                accountID: accountID,
                statusFilter: query.status
            )
        case .spending:
            try await refreshSpendingTransactions(budgetID: budgetID, statusFilter: query.status)
        }
    }

    func loadOlderTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        guard query.text == nil, !query.hasStructuredConditions else {
            throw LocalFirstError.unsupportedWrite
        }
        switch scope {
        case .account(let accountID):
            try await loadOlderTransactions(
                budgetID: budgetID,
                accountID: accountID,
                statusFilter: query.status
            )
        case .spending:
            try await loadOlderSpendingTransactions(budgetID: budgetID, statusFilter: query.status)
        }
    }

    func transactionPage(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        guard !query.hasStructuredConditions, let text = query.text else {
            throw LocalFirstError.unsupportedWrite
        }
        let loaded: LoadedAccountTransactions = switch scope {
        case .account(let accountID):
            try await searchAccountTransactions(
                budgetID: budgetID,
                accountID: accountID,
                query: text,
                limit: limit,
                offset: offset,
                statusFilter: query.status
            )
        case .spending:
            try await searchSpendingTransactions(
                budgetID: budgetID,
                query: text,
                limit: limit,
                offset: offset,
                statusFilter: query.status
            )
        }
        guard let typed = loaded.replacingFixtureQueryMetadata(for: query) else {
            throw FeedTestError("typed query fixture is missing exact metadata")
        }
        return typed
    }
}

private extension LoadedAccountTransactions {
    func replacingFixtureQueryMetadata(
        for query: TransactionFeedQuery
    ) -> LoadedAccountTransactions? {
        guard let queryMetadata else { return nil }
        return LoadedAccountTransactions(
            transactions: transactions,
            balance: balance,
            accountNames: accountNames,
            categoryNames: categoryNames,
            payeeNames: payeeNames,
            transferPayeeIDs: transferPayeeIDs,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: offBudgetAccountIDs,
            reachedEnd: reachedEnd,
            nextOffset: nextOffset,
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: queryMetadata.totalMatchCount,
                querySignature: query.signature,
                matchingTransactionIDs: queryMetadata.matchingTransactionIDs,
                contributingTransactionIDs: queryMetadata.contributingTransactionIDs,
                attachedContextTransactionIDs: queryMetadata.attachedContextTransactionIDs
            )
        )
    }
}
