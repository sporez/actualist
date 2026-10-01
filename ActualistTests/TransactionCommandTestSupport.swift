import Foundation
import Testing
@testable import Actualist

func makeCommandContext() -> TransactionSelectionContext {
    TransactionSelectionContext(
        budgetID: "budget",
        sessionGeneration: 1,
        scope: .spending,
        querySignature: TransactionFeedQuery().signature
    )
}

func identity(
    _ transactionID: String,
    familyRootID: String? = nil,
    role: TransactionSelectionIdentity.Role = .root
) throws -> TransactionSelectionIdentity {
    try #require(TransactionSelectionIdentity(
        transactionID: transactionID,
        familyRootID: familyRootID ?? transactionID,
        role: role
    ))
}

func transaction(id: String) -> ActualTransaction {
    ActualTransaction(
        id: id,
        account: "account",
        date: "2026-09-01",
        amount: -100,
        payee: nil,
        payeeName: nil,
        importedPayee: nil,
        category: nil,
        notes: nil,
        cleared: .bool(false)
    )
}
