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
            code: try SyncedPreferences.value(.defaultCurrencyCode, in: self, db: db) ?? "",
            hideFraction: try SyncedPreferences.value(.hideFraction, in: self, db: db) == "true",
            numberFormat: ActualNumberFormat(
                preference: try SyncedPreferences.value(.numberFormat, in: self, db: db)
            )
        )
    }
}
