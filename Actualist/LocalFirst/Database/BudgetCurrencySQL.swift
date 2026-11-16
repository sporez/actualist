import Foundation
import GRDB

enum BudgetCurrencySQL {
    static func fetchBudgetCurrency(in database: isolated BudgetDatabase) throws -> BudgetCurrency {
        try database.queue.read { db in
            try budgetCurrency(in: database, db: db)
        }
    }

    static func budgetCurrency(in database: isolated BudgetDatabase, db: Database) throws -> BudgetCurrency {
        BudgetCurrency.catalog(
            code: try SyncedPreferences.value(.defaultCurrencyCode, in: database, db: db) ?? "",
            hideFraction: try SyncedPreferences.value(.hideFraction, in: database, db: db) == "true",
            numberFormat: ActualNumberFormat(
                preference: try SyncedPreferences.value(.numberFormat, in: database, db: db)
            )
        )
    }
}
