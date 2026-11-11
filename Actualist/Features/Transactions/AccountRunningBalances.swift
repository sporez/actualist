import Foundation

/// Balance after each displayed row, following Actual's
/// `calculateRunningBalancesTopDown`: rows are newest first, the first row
/// carries the starting balance, and each next row is the balance above it
/// minus the amount above it.
struct AccountRunningBalances: Equatable {
    private let balancesByRowID: [String: Int]

    init(rows: [ActualTransaction], startingBalance: Int) {
        var balances: [String: Int] = [:]
        var balance = startingBalance
        for row in rows {
            balances[row.rowID] = balance
            balance -= row.amount ?? 0
        }
        balancesByRowID = balances
    }

    func balance(forRowID rowID: String) -> Int? {
        balancesByRowID[rowID]
    }
}
