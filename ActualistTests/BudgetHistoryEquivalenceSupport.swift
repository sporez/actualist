import Foundation
import GRDB
@testable import Actualist

/// Deterministic generator so fixtures and their golden digests are stable.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Randomized budget and spending history for the Phase 5 equivalence tests:
/// 24 consecutive months of rows with gaps, plus optional stray early months.
enum BudgetHistoryFixture {
    enum Early {
        case none
        /// Zero-valued rows from 1900 (a stray import artifact).
        case junk
        /// A real, non-zero row in 1905 followed by a long empty stretch.
        case real
    }

    static let expenseCategories = ["groceries", "dining", "rent", "fun", "savings"]

    static func sql(
        seed: UInt64,
        tracking: Bool,
        early: Early = .none,
        firstMonth: Int = 202409,
        monthCount: Int = 24,
        goalDefs: [String: String] = [:]
    ) -> String {
        var rng = SplitMix64(seed: seed)
        var statements: [String] = []
        if !goalDefs.isEmpty {
            statements.append("ALTER TABLE categories ADD COLUMN goal_def TEXT;")
        }
        statements.append("""
            INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            """)
        for (index, id) in expenseCategories.enumerated() where id != "groceries" {
            statements.append("""
                INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                    VALUES ('\(id)', '\(id.capitalized)', 'group', 0, 0, 0, \(index + 2));
                INSERT INTO category_mapping VALUES ('\(id)', '\(id)');
                """)
        }
        for (id, json) in goalDefs.sorted(by: { $0.key < $1.key }) {
            statements.append("UPDATE categories SET goal_def = '\(json)' WHERE id = '\(id)';")
        }
        if tracking {
            statements.append("""
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences VALUES ('budgetType', 'tracking');
                CREATE TABLE reflect_budgets (
                    id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER, carryover INTEGER
                );
                """)
        }

        func budgetRow(month: Int, category: String, amount: Int, carryover: Bool) -> String {
            let flag = carryover ? 1 : 0
            return tracking
                ? "INSERT INTO reflect_budgets VALUES ('\(month)-\(category)', \(month), '\(category)', \(amount), \(flag));"
                : "INSERT INTO zero_budgets VALUES (\(month), '\(category)', \(amount), \(flag));"
        }
        var transactionNumber = 0
        func transaction(month: Int, category: String, amount: Int) -> String {
            transactionNumber += 1
            return """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                    VALUES ('hist-\(seed)-\(transactionNumber)', 'checking', \(month * 100 + 15), \(amount), '\(category)', 0, NULL, 0);
                """
        }

        switch early {
        case .none:
            break
        case .junk:
            for category in ["dining", "rent", "ghost"] {
                statements.append(budgetRow(month: 190001, category: category, amount: 0, carryover: false))
            }
            statements.append(budgetRow(month: 190002, category: "fun", amount: 0, carryover: false))
            statements.append(transaction(month: 190003, category: "dining", amount: 0))
        case .real:
            statements.append(budgetRow(month: 190501, category: "rent", amount: 100, carryover: false))
            statements.append(budgetRow(month: 190502, category: "fun", amount: 0, carryover: true))
        }

        var month = firstMonth
        for _ in 0..<monthCount {
            for category in expenseCategories + ["salary"] {
                // The base fixture already owns July 2026 for groceries.
                let ownedByBase = category == "groceries" && month == 202607
                if !ownedByBase, Int.random(in: 0..<10, using: &rng) < 7 {
                    let income = category == "salary"
                    let amount = income
                        ? Int.random(in: 0...400_000, using: &rng)
                        : Int.random(in: -5_000...60_000, using: &rng)
                    statements.append(budgetRow(
                        month: month,
                        category: category,
                        amount: amount,
                        carryover: Int.random(in: 0..<4, using: &rng) == 0
                    ))
                }
                if Int.random(in: 0..<10, using: &rng) < 6 {
                    let income = category == "salary"
                    let amount = income
                        ? Int.random(in: 100_000...450_000, using: &rng)
                        : Int.random(in: -90_000...8_000, using: &rng)
                    statements.append(transaction(month: month, category: category, amount: amount))
                }
            }
            month = month % 100 == 12 ? (month / 100 + 1) * 100 + 1 : month + 1
        }
        return statements.joined(separator: "\n")
    }

    static func digest(_ values: [String: BudgetCategoryValue]) -> String {
        values.sorted { $0.key < $1.key }.map { id, value in
            "\(id):\(value.budgeted),\(value.spent),\(value.balance),\(value.carryover ? 1 : 0)"
        }.joined(separator: ";")
    }
}

/// Collects the SQL a connection prepares while a body runs.
final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ sql: String) {
        lock.lock()
        recorded.append(sql)
        lock.unlock()
    }

    var statements: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Statements whose text contains every fragment.
    func count(containing fragments: String...) -> Int {
        statements.filter { statement in fragments.allSatisfy(statement.contains) }.count
    }
}

extension BudgetDatabase {
    /// Records the SQL this connection prepares until `stopStatementTraceForTesting`.
    /// The queue has one connection, so a trace set here covers later reads.
    func startStatementTraceForTesting(_ log: StatementLog) throws {
        try queue.write { db in
            db.trace(options: .statement) { event in log.append(event.description) }
        }
    }

    func stopStatementTraceForTesting() throws {
        try queue.write { db in db.trace(options: .statement, nil) }
    }

    /// The pre-Phase-5 recurrence: every month from the earliest data month.
    func naiveCategoryValuesForTesting(
        inputs: BudgetCategoryValueInputs,
        through month: String
    ) throws -> (
        current: [String: BudgetCategoryValue],
        previous: [String: BudgetCategoryValue],
        monthsComputed: Int
    ) {
        let targetMonthInt = monthInt(month)
        let earliestMonthInt = Array(
            Set(inputs.budgetedByMonth.keys).union(inputs.spentByMonth.keys)
        )
            .compactMap { canonicalMonthID($0).map(monthInt) }
            .filter { $0 <= targetMonthInt }
            .min() ?? targetMonthInt
        var valuesByCategory: [String: BudgetCategoryValue] = [:]
        var previousValues: [String: BudgetCategoryValue] = [:]
        var monthsComputed = 0
        var monthCursor = earliestMonthInt
        while monthCursor <= targetMonthInt {
            let budgetMonth = monthID(monthCursor)
            let budgeted = inputs.budgetedByMonth[budgetMonth] ?? [:]
            let spent = inputs.spentByMonth[budgetMonth] ?? [:]
            let categoryIDs = Set(budgeted.keys).union(spent.keys).union(valuesByCategory.keys)
            var nextValues: [String: BudgetCategoryValue] = [:]
            for categoryID in categoryIDs {
                let budget = budgeted[categoryID] ?? (budgeted: 0, carryover: false)
                nextValues[categoryID] = try BudgetFinancialCalculation.category(
                    table: inputs.table,
                    isIncome: inputs.incomeByCategory[categoryID] ?? false,
                    budgeted: budget.budgeted,
                    activity: spent[categoryID] ?? 0,
                    carryover: budget.carryover,
                    previous: valuesByCategory[categoryID] ?? BudgetCategoryValue()
                )
            }
            previousValues = valuesByCategory
            valuesByCategory = nextValues
            monthsComputed += 1
            monthCursor = nextMonth(after: monthCursor)
        }
        return (valuesByCategory, previousValues, monthsComputed)
    }
}
