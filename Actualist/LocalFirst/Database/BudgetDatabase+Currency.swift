import Foundation
import GRDB

extension BudgetDatabase {
    func fetchBudgetCurrency() throws -> BudgetCurrency {
        try queue.read { db in
            try budgetCurrency(db: db)
        }
    }

    func budgetCurrency(db: Database) throws -> BudgetCurrency {
        BudgetCurrency.catalog(
            code: try preferenceValue("defaultCurrencyCode", db: db) ?? "",
            hideFraction: try preferenceValue("hideFraction", db: db) == "true"
        )
    }
}
