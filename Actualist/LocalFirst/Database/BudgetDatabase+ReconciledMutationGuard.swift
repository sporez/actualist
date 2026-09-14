import Foundation
import GRDB

extension BudgetDatabase {
    func validateReconciledMutationPrecondition(
        _ precondition: ReconciledTransactionMutationPrecondition?,
        db: Database
    ) throws {
        guard let precondition else { return }
        let columns = try resolveTransactionRowColumns(db: db)
        try validateReconciledMutationAuthorization(
            transactionID: precondition.transactionID,
            authorization: precondition.authorization,
            columns: columns,
            db: db
        )
    }

    func reconciledMutationReview(
        transactionID: String
    ) throws -> ReconciledTransactionMutationReview? {
        let requestedID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        return try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            return try reconciledMutationReview(
                transactionID: requestedID,
                columns: columns,
                db: db
            )
        }
    }

    func validateReconciledMutationAuthorization(
        transactionID: String,
        authorization: ReconciledTransactionMutationAuthorization?,
        columns: TransactionRowColumns,
        db: Database
    ) throws {
        if let authorization, authorization.transactionID != transactionID {
            throw LocalFirstError.invalidLocalWrite(
                "reconciled transaction authorization does not match the transaction"
            )
        }
        guard let review = try reconciledMutationReview(
            transactionID: transactionID,
            columns: columns,
            db: db
        ) else {
            return
        }
        guard authorization == review.authorization else {
            throw ReconciledTransactionMutationError.confirmationRequired(review)
        }
    }

    private struct ReconciledMutationRow {
        let id: String
        let reconciled: Bool
        let transferID: String?
    }

    private func reconciledMutationReview(
        transactionID: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> ReconciledTransactionMutationReview? {
        let targetFamily = try reconciledMutationFamily(
            containing: transactionID,
            columns: columns,
            db: db
        )
        guard !targetFamily.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        let targetIDs = Set(targetFamily.map(\.id))
        let targetReconciled = targetFamily.filter(\.reconciled).map(\.id).sorted()
        let pairedIDs = Set(targetFamily.compactMap(\.transferID)).subtracting(targetIDs)
        var pairedReconciled = Set<String>()
        for pairedID in pairedIDs {
            let pairedFamily = try reconciledMutationFamily(
                containing: pairedID,
                columns: columns,
                db: db
            )
            pairedReconciled.formUnion(
                pairedFamily.lazy.filter(\.reconciled).map(\.id)
            )
        }
        pairedReconciled.subtract(targetIDs)

        guard !targetReconciled.isEmpty || !pairedReconciled.isEmpty else {
            return nil
        }
        return ReconciledTransactionMutationReview(
            transactionID: transactionID,
            targetReconciledTransactionIDs: targetReconciled,
            pairedReconciledTransactionIDs: pairedReconciled.sorted()
        )
    }

    private func reconciledMutationFamily(
        containing transactionID: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> [ReconciledMutationRow] {
        let split = transactionSplitQueryExpressions(columns: columns.all)
        let target = try Row.fetchOne(
            db,
            sql: """
                SELECT t.id, \(split.effectiveParentID) AS parent_id
                FROM transactions t
                \(split.parentJoin())
                WHERE t.id = ? AND \(split.liveEffectivePredicate())
                LIMIT 1
                """,
            arguments: [transactionID]
        )
        guard let target else { return [] }
        let rootID = (target["parent_id"] as String?) ?? transactionID
        let transfer = columns.transferID.map { "t.\($0)" } ?? "NULL"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT t.id, \(split.qualifiedReconciled) AS reconciled,
                       \(transfer) AS transfer_id
                FROM transactions t
                \(split.parentJoin())
                WHERE (t.id = ? OR \(split.effectiveParentID) = ?)
                  AND \(split.liveEffectivePredicate())
                """,
            arguments: [rootID, rootID]
        ).compactMap { row in
            guard let id = row["id"] as String? else { return nil }
            return ReconciledMutationRow(
                id: id,
                reconciled: flexibleBool(row["reconciled"]),
                transferID: (row["transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}
