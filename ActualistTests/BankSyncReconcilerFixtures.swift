import Foundation
@testable import Actualist

/// Shared builders for the pure bank-sync reconciler suites. Each suite
/// conforms to reuse them; no network, no writes.
protocol BankSyncReconcilerFixtures {}

extension BankSyncReconcilerFixtures {
    func candidate(
        id: String? = nil,
        day: String = "20240301",
        amount: Int = -1_000,
        payee: String? = "payee-a",
        notes: String? = nil,
        category: String? = nil,
        cleared: Bool = true,
        importedPayee: String? = nil
    ) -> BankSyncReconciliation.Candidate {
        BankSyncReconciliation.Candidate(
            financialID: id,
            dayID: day,
            amountMinorUnits: amount,
            payeeID: payee,
            notes: notes,
            categoryID: category,
            cleared: cleared,
            importedPayee: importedPayee ?? "Steam"
        )
    }

    func existing(
        id: String,
        financialID: String? = nil,
        day: String = "20240301",
        amount: Int = -1_000,
        payee: String? = "payee-a",
        category: String? = nil,
        notes: String? = nil,
        cleared: Bool = false,
        reconciled: Bool = false,
        importedPayee: String? = nil,
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil,
        transferID: String? = nil
    ) -> BankSyncReconciliation.Existing {
        BankSyncReconciliation.Existing(
            id: id,
            financialID: financialID,
            dayID: day,
            amountMinorUnits: amount,
            payeeID: payee,
            categoryID: category,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            importedPayee: importedPayee,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            transferID: transferID
        )
    }

    func insertIDs(_ plan: BankSyncReconciliation.Plan) -> [BankSyncReconciliation.Candidate] {
        plan.entries.compactMap { entry in
            if case .insert(let candidate) = entry { return candidate }
            return nil
        }
    }

    func update(for existingID: String, _ plan: BankSyncReconciliation.Plan) -> BankSyncReconciliation.MatchedUpdate? {
        for entry in plan.entries {
            if case .update(let matched) = entry, matched.existingID == existingID {
                return matched
            }
        }
        return nil
    }

    func isUnchanged(_ existingID: String, _ plan: BankSyncReconciliation.Plan) -> Bool {
        plan.entries.contains { entry in
            if case .unchanged(let id) = entry { return id == existingID }
            return false
        }
    }
}
