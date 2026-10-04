import Foundation
import GRDB

extension BudgetDatabase {
    /// Rejects split drafts whose child ids would collide. Explicit ids must be
    /// unique, must not be the parent, and must be either an existing child of
    /// this family (update in place) or absent from `transactions`. A foreign
    /// id would otherwise overwrite an unrelated row, and a duplicate id traps
    /// in `persistFamilyChange`'s `Dictionary(uniqueKeysWithValues:)`.
    func validateSplitDraftIDs(
        _ splits: [TransactionSplitDraft],
        parentID: String,
        familyChildIDs: Set<String>,
        db: Database
    ) throws {
        var seen = Set<String>()
        for id in splits.compactMap(\.id) {
            guard id != parentID, seen.insert(id).inserted else {
                throw LocalFirstError.invalidLocalWrite("invalid split child id")
            }
            if !familyChildIDs.contains(id),
               try rowExists(table: "transactions", rowID: id, db: db) {
                throw LocalFirstError.invalidLocalWrite("invalid split child id")
            }
        }
    }
}
