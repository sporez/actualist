import Foundation
import GRDB

private struct BudgetTemplateLimitState {
    let limitAmount: Int
    let fromLastMonth: Int
    let holdsExcess: Bool

    var isInitiallyMet: Bool {
        fromLastMonth >= limitAmount
    }

    var initialBudgetedAmount: Int {
        guard isInitiallyMet, !holdsExcess else {
            return 0
        }
        return limitAmount - fromLastMonth
    }

    var releasedExcess: Int {
        max(0, -initialBudgetedAmount)
    }
}

extension BudgetDatabase {

    func createAccountMessages(
        accountID: String,
        name: String,
        offbudget: Bool,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard !trimmedName.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account name")
        }

        return try queue.read { db in
            let accountColumns = try requiredColumns(
                table: "accounts",
                required: ["name"],
                db: db
            )
            if try rowExists(table: "accounts", rowID: trimmedAccountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("account already exists")
            }

            var messages: [ActualSyncDecodedMessage] = [
                try builder.makeMessage(
                    dataset: "accounts",
                    row: trimmedAccountID,
                    column: "name",
                    value: .string(trimmedName)
                )
            ]
            if accountColumns.contains("offbudget") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "offbudget",
                        value: .bool(offbudget)
                    )
                )
            }
            if accountColumns.contains("closed") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "closed",
                        value: .bool(false)
                    )
                )
            }
            if accountColumns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }
            if accountColumns.contains("sort_order") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "accounts",
                        row: trimmedAccountID,
                        column: "sort_order",
                        value: .int(Int64(nextAccountSortOrder(offbudget: offbudget, db: db)))
                    )
                )
            }

            messages += try transferPayeeMessages(forAccountID: trimmedAccountID, db: db, builder: &builder)
            return messages
        }
    }

    func assignCategoryBudgetMessages(
        categoryID: String,
        budgeted: Int,
        month: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        let monthValue = try Self.actualMonthValue(month)

        return try queue.read { db in
            let columns = try requiredColumns(
                table: "zero_budgets",
                required: ["month", "category", "amount"],
                db: db
            )
            if try tableExists("categories", db: db),
               try !rowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            return try assignCategoryBudgetMessages(
                categoryID: trimmedCategoryID,
                budgeted: budgeted,
                monthValue: monthValue,
                columns: columns,
                db: db,
                builder: &builder
            )
        }
    }

    /// Matches Actual's native rollover mutation: update every budget month from the selected
    /// month through the already-created budget horizon, rather than changing only one month.
    func categoryCarryoverMessages(
        categoryID: String,
        carryover: Bool,
        startMonth: String,
        throughMonth: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        let startMonthValue = try Self.actualMonthValue(startMonth)
        let throughMonthValue = try Self.actualMonthValue(throughMonth)
        guard throughMonthValue >= startMonthValue else {
            throw LocalFirstError.invalidLocalWrite("invalid carryover month range")
        }

        return try queue.read { db in
            let columns = try requiredColumns(
                table: "zero_budgets",
                required: ["month", "category", "carryover"],
                db: db
            )
            try validateBudgetCategoryID(trimmedCategoryID, db: db)

            var messages: [ActualSyncDecodedMessage] = []
            var monthValue = startMonthValue
            while monthValue <= throughMonthValue {
                let existingRowID = try zeroBudgetRowID(
                    monthValue: monthValue,
                    categoryID: trimmedCategoryID,
                    columns: columns,
                    db: db
                )
                let rowID = existingRowID
                    ?? Self.zeroBudgetRowID(monthValue: monthValue, categoryID: trimmedCategoryID)

                // Identity columns travel with the mutation so another Actual client can create
                // a missing zero_budgets row and still attach it to the correct month/category.
                messages.append(
                    try builder.makeMessage(
                        dataset: "zero_budgets",
                        row: rowID,
                        column: "month",
                        value: .int(Int64(monthValue))
                    )
                )
                messages.append(
                    try builder.makeMessage(
                        dataset: "zero_budgets",
                        row: rowID,
                        column: "category",
                        value: .string(trimmedCategoryID)
                    )
                )
                messages.append(
                    try builder.makeMessage(
                        dataset: "zero_budgets",
                        row: rowID,
                        column: "carryover",
                        value: .bool(carryover)
                    )
                )

                monthValue = nextMonth(after: monthValue)
            }
            return messages
        }
    }

    func budgetTemplateMessages(
        command: BudgetTemplateCommand,
        month: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let monthValue = try Self.actualMonthValue(month)

        return try queue.read { db in
            let columns = try requiredColumns(
                table: "zero_budgets",
                required: ["month", "category", "amount"],
                db: db
            )
            let goalDefsRaw = try readCategoryGoalDefsRaw(db: db)
            let categoryNames = try templateCategoryNames(db: db)
            let targeted = Set(
                command.categoryIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            let scope: [String]
            if targeted.isEmpty {
                scope = try templateScopeCategoryIDs(db: db).filter { goalDefsRaw[$0] != nil }
            } else {
                scope = targeted.filter { goalDefsRaw[$0] != nil }.sorted()
            }
            // Category-targeted and whole-month "overwrite" force the value; "fillEmpty" only fills
            // categories with a zero budget.
            let force = command.mode == .overwrite || !targeted.isEmpty
            let currentBudgets = try categoryBudgets(month: monthID(monthValue), db: db)

            var unsupported: [String] = []
            var categoryTemplates: [String: [BudgetTemplateEntry]] = [:]
            var availableBudget = try monthToBudget(month: monthID(monthValue), db: db)
            for categoryID in scope {
                guard let json = goalDefsRaw[categoryID] else { continue }
                let currentBudgeted = currentBudgets[categoryID]?.budgeted ?? 0
                // fillEmpty skips already-budgeted categories, so they never need a support check.
                guard force || currentBudgeted == 0 else { continue }

                do {
                    if let entries = try decodeSupportedTemplateEntries(json: json) {
                        try validateTemplateEntries(entries, for: monthValue)
                        categoryTemplates[categoryID] = entries
                        availableBudget += currentBudgeted
                    }
                } catch LocalFirstError.unsupportedTemplate(let reason) {
                    unsupported.append(
                        "\(categoryNames[categoryID] ?? categoryID) (\(reason))"
                    )
                    continue
                } catch {
                    unsupported.append(
                        "\(categoryNames[categoryID] ?? categoryID) (unreadable template definition)"
                    )
                    continue
                }
            }

            guard unsupported.isEmpty else {
                throw LocalFirstError.unsupportedTemplate(
                    "categories use template types not supported yet: \(unsupported.sorted().joined(separator: ", "))"
                )
            }

            let writes = try computeTemplateWrites(
                categoryTemplates: categoryTemplates,
                monthValue: monthValue,
                availableBudget: availableBudget,
                db: db
            )

            var messages: [ActualSyncDecodedMessage] = []
            for write in writes.sorted(by: { $0.categoryID < $1.categoryID }) {
                messages += try assignCategoryBudgetMessages(
                    categoryID: write.categoryID,
                    budgeted: write.amount,
                    monthValue: monthValue,
                    columns: columns,
                    db: db,
                    builder: &builder
                )
            }
            return messages
        }
    }

    func decodeSupportedTemplateEntries(json: String) throws -> [BudgetTemplateEntry]? {
        guard let data = json.data(using: .utf8) else {
            throw LocalFirstError.unsupportedTemplate("template definition is not UTF-8")
        }
        let entries: [BudgetTemplateEntry]
        do {
            entries = try JSONDecoder().decode([BudgetTemplateEntry].self, from: data)
        } catch {
            throw LocalFirstError.unsupportedTemplate(templateDecodingFailureReason(error))
        }
        let budgetEntries = entries.filter(\.setsBudget)
        guard !budgetEntries.isEmpty else {
            return nil
        }
        for entry in budgetEntries {
            try validateTemplateEntryIsT1Constant(entry)
        }
        try validateTemplateEntryInteractions(budgetEntries)
        return budgetEntries
    }

    private func nextAccountSortOrder(offbudget: Bool, db: Database) throws -> Int {
        let columns = try columnSet(for: "accounts", db: db)
        guard columns.contains("sort_order") else {
            return 16_384
        }
        let offbudgetColumn = column("offbudget", fallback: "0", columns: columns)
        let maxSortOrder = try Int.fetchOne(
            db,
            sql: "SELECT MAX(sort_order) FROM accounts WHERE \(offbudgetColumn) = ?",
            arguments: [offbudget ? 1 : 0]
        )
        return (maxSortOrder ?? 0) + 16_384
    }

    private func transferPayeeMessages(
        forAccountID accountID: String,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard try tableExists("payees", db: db) else {
            return []
        }
        let payeeColumns = try requiredColumns(table: "payees", required: ["name"], db: db)
        let transferColumn = payeeColumns.contains("transfer_acct") ? "transfer_acct" : (
            payeeColumns.contains("transferAccount") ? "transferAccount" : nil
        )
        guard let transferColumn else {
            return []
        }

        let payeeID = UUID().uuidString
        var fields: [(String, LocalFirstSyncValue)] = [
            ("name", .string("")),
            (transferColumn, .string(accountID))
        ]
        if payeeColumns.contains("tombstone") {
            fields.append(("tombstone", .bool(false)))
        }
        if payeeColumns.contains("favorite") {
            fields.append(("favorite", .bool(false)))
        }
        if payeeColumns.contains("learn_categories") {
            fields.append(("learn_categories", .bool(false)))
        }
        if payeeColumns.contains("category") {
            fields.append(("category", .null))
        }

        var messages = try fields.map { field in
            try builder.makeMessage(dataset: "payees", row: payeeID, column: field.0, value: field.1)
        }

        if try tableExists("payee_mapping", db: db) {
            let mappingColumns = try requiredColumns(table: "payee_mapping", required: [], db: db)
            let targetColumn = try firstExistingColumn(
                ["targetId", "target_id"],
                in: mappingColumns,
                table: "payee_mapping"
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "payee_mapping",
                    row: payeeID,
                    column: targetColumn,
                    value: .string(payeeID)
                )
            )
        }
        return messages
    }

    func validateTemplateEntryIsT1Constant(_ entry: BudgetTemplateEntry) throws {
        guard (entry.priority ?? 0) >= 0 else {
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
        switch entry.type {
        case "simple":
            guard entry.monthly != nil || entry.limit != nil else {
                throw LocalFirstError.unsupportedTemplate("simple without monthly amount")
            }
            try validateBasicMonthlyTemplateLimit(entry.limit)
        case "periodic":
            guard entry.amount != nil,
                  let periodAmount = entry.period?.amount,
                  periodAmount > 0,
                  let period = entry.period?.period,
                  ["day", "week", "month", "year"].contains(period) else {
                throw LocalFirstError.unsupportedTemplate("periodic")
            }
            if let starting = entry.starting, !starting.isEmpty, date(fromDayID: starting) == nil {
                throw LocalFirstError.unsupportedTemplate("periodic start date")
            }
            try validateBasicMonthlyTemplateLimit(entry.limit)
        case "copy":
            guard let lookBack = entry.lookBack,
                  lookBack >= 0,
                  entry.limit == nil else {
                throw LocalFirstError.unsupportedTemplate("copy")
            }
        case "by":
            guard let amount = entry.amount,
                  amount >= 0,
                  validTemplateMonth(entry.month),
                  entry.limit == nil,
                  entry.repeatInterval.map({ $0 > 0 }) ?? true else {
                throw LocalFirstError.unsupportedTemplate("invalid by template")
            }
        case "limit":
            guard entry.standaloneLimit != nil else {
                throw LocalFirstError.unsupportedTemplate(
                    "up-to limit is missing its amount or period"
                )
            }
            try validateBasicMonthlyTemplateLimit(entry.standaloneLimit)
        case "refill":
            guard entry.limit == nil else {
                throw LocalFirstError.unsupportedTemplate("invalid refill template")
            }
        default:
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
    }

    private func validateTemplateEntryInteractions(_ entries: [BudgetTemplateEntry]) throws {
        let byPriorities = Set(
            entries.filter { $0.type == "by" }.map { $0.priority ?? 0 }
        )
        guard byPriorities.count <= 1 else {
            throw LocalFirstError.unsupportedTemplate(
                "all by templates in a category must use the same priority"
            )
        }

        let limits = entries.filter {
            $0.limit != nil || $0.standaloneLimit != nil
        }
        guard limits.count <= 1 else {
            throw LocalFirstError.unsupportedTemplate(
                "only one up-to limit is supported per category"
            )
        }

        if entries.contains(where: { $0.type == "refill" }) {
            guard limits.count == 1 else {
                throw LocalFirstError.unsupportedTemplate(
                    "refill requires exactly one up-to limit"
                )
            }
        }
    }

    private func validateTemplateEntries(
        _ entries: [BudgetTemplateEntry],
        for monthValue: Int
    ) throws {
        for entry in entries where entry.type == "by" {
            _ = try resolvedByTarget(entry, monthValue: monthValue)
        }
    }

    private func validateBasicMonthlyTemplateLimit(_ limit: BudgetTemplateLimit?) throws {
        guard let limit else {
            return
        }
        guard let amount = limit.amount,
              amount >= 0,
              limit.period == "monthly",
              limit.start == nil else {
            throw LocalFirstError.unsupportedTemplate(
                "only basic monthly up-to limits are supported"
            )
        }
    }

    private func validTemplateMonth(_ month: String?) -> Bool {
        guard let month,
              let monthValue = try? Self.actualMonthValue(month) else {
            return false
        }
        return (1...12).contains(monthValue % 100)
    }

    func computeTemplateWrites(
        categoryTemplates: [String: [BudgetTemplateEntry]],
        monthValue: Int,
        availableBudget: Int,
        db: Database
    ) throws -> [(categoryID: String, amount: Int)] {
        guard !categoryTemplates.isEmpty else {
            return []
        }

        let limitStates = try Dictionary(
            uniqueKeysWithValues: categoryTemplates.compactMap { item in
                try templateLimitState(
                    entries: item.value,
                    categoryID: item.key,
                    monthValue: monthValue,
                    db: db
                ).map { (item.key, $0) }
            }
        )
        var remainingAvailable = availableBudget
            + limitStates.values.reduce(0) { $0 + $1.releasedExcess }
        var budgetedByCategory = Dictionary(uniqueKeysWithValues: categoryTemplates.keys.map { ($0, 0) })
        for (categoryID, state) in limitStates where state.isInitiallyMet {
            budgetedByCategory[categoryID] = state.initialBudgetedAmount
        }
        let priorities = Set(categoryTemplates.values.flatMap { entries in
            entries.map { $0.priority ?? 0 }
        }).sorted()

        for priority in priorities {
            for categoryID in categoryTemplates.keys.sorted() {
                let entries = categoryTemplates[categoryID, default: []].filter { ($0.priority ?? 0) == priority }
                guard !entries.isEmpty,
                      limitStates[categoryID]?.isInitiallyMet != true else {
                    continue
                }

                var amount = 0
                let byEntries = entries.filter { $0.type == "by" }
                if !byEntries.isEmpty {
                    amount += try computeByTemplateAmount(
                        byEntries,
                        categoryID: categoryID,
                        monthValue: monthValue,
                        db: db
                    )
                }
                for entry in entries where entry.type != "by" {
                    amount += try computeTemplateEntryAmount(
                        entry,
                        categoryID: categoryID,
                        monthValue: monthValue,
                        limitState: limitStates[categoryID],
                        db: db
                    )
                }

                if let limitState = limitStates[categoryID] {
                    let alreadyBudgeted = budgetedByCategory[categoryID, default: 0]
                    let availableBeforeLimit = max(
                        0,
                        limitState.limitAmount - limitState.fromLastMonth - alreadyBudgeted
                    )
                    if amount > availableBeforeLimit {
                        amount = availableBeforeLimit
                    }
                }

                if priority > 0, amount > 0, remainingAvailable < amount {
                    amount = max(0, remainingAvailable)
                }

                budgetedByCategory[categoryID, default: 0] += amount
                remainingAvailable -= amount
            }
        }

        return budgetedByCategory.map { (categoryID: $0.key, amount: $0.value) }
    }

    private func computeTemplateEntryAmount(
        _ entry: BudgetTemplateEntry,
        categoryID: String,
        monthValue: Int,
        limitState: BudgetTemplateLimitState? = nil,
        db: Database
    ) throws -> Int {
        switch entry.type {
        case "simple":
            if let monthly = entry.monthly {
                return Self.templateAmountToMinorUnits(monthly)
            }
            guard let limitState else {
                throw LocalFirstError.unsupportedTemplate("simple without monthly amount")
            }
            return limitState.limitAmount - limitState.fromLastMonth
        case "periodic":
            return try computePeriodicTemplateAmount(entry, monthValue: monthValue)
        case "copy":
            return try copyTemplateAmount(entry, categoryID: categoryID, monthValue: monthValue, db: db)
        case "limit":
            return 0
        case "refill":
            guard let limitState else {
                throw LocalFirstError.unsupportedTemplate("refill without up-to limit")
            }
            return limitState.limitAmount - limitState.fromLastMonth
        default:
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
    }

    private func templateLimitState(
        entries: [BudgetTemplateEntry],
        categoryID: String,
        monthValue: Int,
        db: Database
    ) throws -> BudgetTemplateLimitState? {
        let limits = entries.compactMap { entry in
            entry.type == "limit" ? entry.standaloneLimit : entry.limit
        }
        guard !limits.isEmpty else {
            return nil
        }
        guard limits.count == 1, let limit = limits.first, let amount = limit.amount else {
            throw LocalFirstError.unsupportedTemplate(
                "only one up-to limit is supported per category"
            )
        }

        return BudgetTemplateLimitState(
            limitAmount: Self.templateAmountToMinorUnits(amount),
            fromLastMonth: try templateFromLastMonth(
                categoryID: categoryID,
                monthValue: monthValue,
                db: db
            ),
            holdsExcess: limit.hold == true
        )
    }

    private func templateFromLastMonth(
        categoryID: String,
        monthValue: Int,
        db: Database
    ) throws -> Int {
        let previousMonth = monthID(shiftedMonth(monthValue, by: -1))
        let previousValues = try envelopeCategoryValues(through: previousMonth, db: db)[categoryID]
            ?? EnvelopeCategoryValue()
        if try templateCategoryIsIncome(categoryID, db: db) {
            return 0
        }
        if previousValues.balance < 0, !previousValues.carryover {
            return 0
        }
        return previousValues.balance
    }

    private func templateCategoryIsIncome(_ categoryID: String, db: Database) throws -> Bool {
        guard try tableExists("categories", db: db) else {
            return false
        }
        let columns = try columnSet(for: "categories", db: db)
        let isIncome = column("is_income", fallback: "0", columns: columns)
        let value = try Int.fetchOne(
            db,
            sql: """
                SELECT \(isIncome)
                FROM categories
                WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                LIMIT 1
                """,
            arguments: [categoryID]
        )
        return value != 0
    }

    func computePeriodicTemplateAmount(
        _ entry: BudgetTemplateEntry,
        monthValue: Int
    ) throws -> Int {
        guard let amount = entry.amount,
              let periodAmount = entry.period?.amount,
              let period = entry.period?.period,
              periodAmount > 0 else {
            throw LocalFirstError.unsupportedTemplate("periodic")
        }

        let templateAmount = Self.templateAmountToMinorUnits(amount)
        let monthStart = "\(monthID(monthValue))-01"
        let nextMonthStart = "\(monthID(nextMonth(after: monthValue)))-01"
        let starting = entry.starting?.trimmingCharacters(in: .whitespacesAndNewlines)
        var currentDateID = monthStart
        if let starting, !starting.isEmpty {
            guard let startingDate = date(fromDayID: starting) else {
                throw LocalFirstError.unsupportedTemplate("periodic start date")
            }
            currentDateID = dayIDString(from: startingDate)
        }

        while compareDayID(currentDateID, monthStart) == .orderedAscending {
            currentDateID = try shiftedPeriodicDate(currentDateID, by: periodAmount, period: period)
        }
        guard compareDayID(currentDateID, nextMonthStart) == .orderedAscending else {
            return 0
        }

        var total = 0
        while compareDayID(currentDateID, nextMonthStart) == .orderedAscending {
            total += templateAmount
            currentDateID = try shiftedPeriodicDate(currentDateID, by: periodAmount, period: period)
        }
        return total
    }

    func copyTemplateAmount(
        _ entry: BudgetTemplateEntry,
        categoryID: String,
        monthValue: Int,
        db: Database
    ) throws -> Int {
        guard let lookBack = entry.lookBack, lookBack >= 0 else {
            throw LocalFirstError.unsupportedTemplate("copy")
        }
        let sourceMonth = monthID(shiftedMonth(monthValue, by: -lookBack))
        return try categoryBudgets(month: sourceMonth, db: db)[categoryID]?.budgeted ?? 0
    }

    private func computeByTemplateAmount(
        _ entries: [BudgetTemplateEntry],
        categoryID: String,
        monthValue: Int,
        db: Database
    ) throws -> Int {
        var targets: [(amount: Int, monthsRemaining: Int, repeatPeriod: Int?)] = []
        targets.reserveCapacity(entries.count)

        for entry in entries {
            targets.append(try resolvedByTarget(entry, monthValue: monthValue))
        }

        guard let shortestTarget = targets.map(\.monthsRemaining).min() else {
            return 0
        }

        var totalNeeded = 0
        for target in targets {
            if target.monthsRemaining > shortestTarget, let repeatPeriod = target.repeatPeriod {
                totalNeeded += Self.actualTemplateRound(
                    Double(target.amount)
                        / Double(repeatPeriod)
                        * Double(repeatPeriod - target.monthsRemaining + shortestTarget)
                )
            } else if target.monthsRemaining > shortestTarget {
                totalNeeded += Self.actualTemplateRound(
                    Double(target.amount)
                        / Double(target.monthsRemaining + 1)
                        * Double(shortestTarget + 1)
                )
            } else {
                totalNeeded += target.amount
            }
        }

        let fromLastMonth = try templateFromLastMonth(
            categoryID: categoryID,
            monthValue: monthValue,
            db: db
        )
        return Self.actualTemplateRound(
            Double(totalNeeded - fromLastMonth) / Double(shortestTarget + 1)
        )
    }

    private func resolvedByTarget(
        _ entry: BudgetTemplateEntry,
        monthValue: Int
    ) throws -> (amount: Int, monthsRemaining: Int, repeatPeriod: Int?) {
        guard let amount = entry.amount,
              let month = entry.month,
              let initialTargetMonth = try? Self.actualMonthValue(month) else {
            throw LocalFirstError.unsupportedTemplate("invalid by template")
        }

        let repeatPeriod: Int?
        if entry.annual == true {
            let years = entry.repeatInterval ?? 1
            guard years <= Int.max / 12 else {
                throw LocalFirstError.unsupportedTemplate("invalid by repeat interval")
            }
            repeatPeriod = years * 12
        } else {
            repeatPeriod = entry.repeatInterval
        }

        var targetMonth = initialTargetMonth
        var monthsRemaining = templateMonthDistance(from: monthValue, to: targetMonth)
        while monthsRemaining < 0, let repeatPeriod {
            targetMonth = shiftedMonth(targetMonth, by: repeatPeriod)
            monthsRemaining = templateMonthDistance(from: monthValue, to: targetMonth)
        }
        guard monthsRemaining >= 0 else {
            throw LocalFirstError.unsupportedTemplate(
                "by target month \(monthID(initialTargetMonth)) has passed"
            )
        }

        return (
            amount: Self.templateAmountToMinorUnits(amount),
            monthsRemaining: monthsRemaining,
            repeatPeriod: repeatPeriod
        )
    }

    private func templateMonthDistance(from currentMonth: Int, to targetMonth: Int) -> Int {
        let currentOrdinal = (currentMonth / 100) * 12 + (currentMonth % 100 - 1)
        let targetOrdinal = (targetMonth / 100) * 12 + (targetMonth % 100 - 1)
        return targetOrdinal - currentOrdinal
    }

    func shiftedPeriodicDate(_ dayID: String, by amount: Int, period: String) throws -> String {
        guard let date = date(fromDayID: dayID) else {
            throw LocalFirstError.unsupportedTemplate("periodic start date")
        }
        var components = DateComponents()
        switch period {
        case "day":
            components.day = amount
        case "week":
            components.day = amount * 7
        case "month":
            components.month = amount
        case "year":
            components.year = amount
        default:
            throw LocalFirstError.unsupportedTemplate("periodic \(period)")
        }
        guard let shifted = Calendar(identifier: .gregorian).date(byAdding: components, to: date) else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        return dayIDString(from: shifted)
    }

    func monthToBudget(month: String, db: Database) throws -> Int {
        let categoryValues = try envelopeCategoryValues(through: month, db: db)
        let groups = try fetchCategoryGroups(categoryValues: categoryValues, db: db)
        let expenseGroups = groups.filter { !$0.isIncome }
        let totalBalance = expenseGroups.reduce(0) { $0 + $1.balance }
        let onBudgetBalance = try onBudgetAccountBalance(through: month, db: db)
        let uncategorizedActivity = try uncategorizedOnBudgetActivity(through: month, db: db)
        return (onBudgetBalance - uncategorizedActivity) - totalBalance
    }

    func readCategoryGoalDefsRaw(db: Database) throws -> [String: String] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        guard columns.contains("goal_def") else {
            return [:]
        }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, goal_def FROM categories WHERE goal_def IS NOT NULL AND \(predicateForLiveRows(columns: columns))"
        )
        var result: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as String?,
                  let json = row["goal_def"] as String?,
                  !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            result[id] = json
        }
        return result
    }

    func templateCategoryNames(db: Database) throws -> [String: String] {
        guard try tableExists("categories", db: db) else {
            return [:]
        }
        let columns = try columnSet(for: "categories", db: db)
        let name = column("name", fallback: "id", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name
                FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["id"] as String? else {
                    return nil
                }
                let rawCategoryName: String? = row["name"]
                let categoryName = rawCategoryName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = categoryName.flatMap { $0.isEmpty ? nil : $0 } ?? id
                return (id, label)
            }
        )
    }

    func templateScopeCategoryIDs(db: Database) throws -> [String] {
        guard try tableExists("categories", db: db) else {
            return []
        }
        let columns = try columnSet(for: "categories", db: db)
        let isIncome = column("is_income", fallback: "0", columns: columns)
        let hidden = column("hidden", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id FROM categories
                WHERE \(predicateForLiveRows(columns: columns))
                  AND (\(isIncome) = 0 OR \(isIncome) IS NULL)
                  AND (\(hidden) = 0 OR \(hidden) IS NULL)
                """
        )
        return rows.compactMap { $0["id"] as String? }
    }

    static func templateAmountToMinorUnits(_ amount: Double) -> Int {
        // goal_def amounts are display decimals; convert with the app's 2-decimal money model.
        Int((amount * 100).rounded())
    }

    private static func actualTemplateRound(_ amount: Double) -> Int {
        Int(floor(amount + 0.5))
    }

    private func templateDecodingFailureReason(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return "can't decode \(templateCodingPath(context)): \(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "can't decode \(templateCodingPath(context)): \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            let parentPath = templateCodingPath(context)
            return "can't decode \(parentPath).\(key.stringValue): missing required field"
        case DecodingError.dataCorrupted(let context):
            return "can't decode \(templateCodingPath(context)): \(context.debugDescription)"
        default:
            return "unreadable template definition"
        }
    }

    private func templateCodingPath(_ context: DecodingError.Context) -> String {
        var path = "template"
        for key in context.codingPath {
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += ".\(key.stringValue)"
            }
        }
        return path
    }

    func moveMoneyMessages(
        commands: [BudgetMoveMoneyCommand],
        month: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !commands.isEmpty else {
            return []
        }
        let monthValue = try Self.actualMonthValue(month)

        return try queue.read { db in
            let columns = try requiredColumns(
                table: "zero_budgets",
                required: ["month", "category", "amount"],
                db: db
            )
            let initialBudgets = try categoryBudgets(month: monthID(monthValue), db: db)
            var budgetedByCategory = initialBudgets.mapValues(\.budgeted)
            var affectedCategoryIDs: Set<String> = []

            for command in commands {
                guard command.amount > 0 else {
                    throw LocalFirstError.invalidLocalWrite("missing amount")
                }
                guard command.fromCategoryID != nil || command.toCategoryID != nil else {
                    throw LocalFirstError.invalidLocalWrite("missing category")
                }
                if let fromCategoryID = command.fromCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    try validateBudgetCategoryID(fromCategoryID, db: db)
                    budgetedByCategory[fromCategoryID, default: 0] -= command.amount
                    affectedCategoryIDs.insert(fromCategoryID)
                }
                if let toCategoryID = command.toCategoryID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    try validateBudgetCategoryID(toCategoryID, db: db)
                    budgetedByCategory[toCategoryID, default: 0] += command.amount
                    affectedCategoryIDs.insert(toCategoryID)
                }
            }

            var messages: [ActualSyncDecodedMessage] = []
            for categoryID in affectedCategoryIDs.sorted() {
                messages.append(contentsOf: try assignCategoryBudgetMessages(
                    categoryID: categoryID,
                    budgeted: budgetedByCategory[categoryID] ?? 0,
                    monthValue: monthValue,
                    columns: columns,
                    db: db,
                    builder: &builder
                ))
            }
            return messages
        }
    }

    func validateBudgetCategoryID(_ categoryID: String, db: Database) throws {
        let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        if try tableExists("categories", db: db),
           try !rowExists(table: "categories", rowID: trimmed, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
    }

    func assignCategoryBudgetMessages(
        categoryID: String,
        budgeted: Int,
        monthValue: Int,
        columns: Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let existingRowID = try zeroBudgetRowID(
            monthValue: monthValue,
            categoryID: categoryID,
            columns: columns,
            db: db
        )
        let rowID = existingRowID ?? Self.zeroBudgetRowID(monthValue: monthValue, categoryID: categoryID)
        var messages: [ActualSyncDecodedMessage] = []
        // A local imported budget can contain zero_budgets rows that the sync server does not
        // yet have as identified CRDT rows. Include the identity columns with every amount write
        // so a remote receiver can attach the row to the correct month/category if it has to
        // create the row from these messages.
        messages.append(
            try builder.makeMessage(
                dataset: "zero_budgets",
                row: rowID,
                column: "month",
                value: .int(Int64(monthValue))
            )
        )
        messages.append(
            try builder.makeMessage(
                dataset: "zero_budgets",
                row: rowID,
                column: "category",
                value: .string(categoryID)
            )
        )
        if existingRowID == nil, columns.contains("carryover") {
            messages.append(
                try builder.makeMessage(
                    dataset: "zero_budgets",
                    row: rowID,
                    column: "carryover",
                    value: .bool(false)
                )
            )
        }
        messages.append(
            try builder.makeMessage(
                dataset: "zero_budgets",
                row: rowID,
                column: "amount",
                value: .int(Int64(budgeted))
            )
        )
        return messages
    }

    func zeroBudgetRowID(
        monthValue: Int,
        categoryID: String,
        columns: Set<String>,
        db: Database
    ) throws -> String? {
        let monthColumn = column("month", fallback: "NULL", columns: columns)
        let categoryColumn = column("category", fallback: "NULL", columns: columns)
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(columns.contains("id") ? "id" : "NULL") AS id
                FROM zero_budgets
                WHERE \(normalizedMonthExpression(monthColumn)) = ? AND \(categoryColumn) = ?
                LIMIT 1
                """,
            arguments: [monthID(monthValue), categoryID]
        )
        if columns.contains("id") {
            return row?["id"] as String?
        }
        return row == nil ? nil : Self.zeroBudgetRowID(monthValue: monthValue, categoryID: categoryID)
    }

    static func zeroBudgetRowID(monthValue: Int, categoryID: String) -> String {
        "\(monthValue)-\(categoryID)"
    }

    func zeroBudgetKey(from rowID: String) throws -> (monthValue: Int, monthID: String, categoryID: String) {
        guard rowID.count > 7 else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets row")
        }
        let monthEnd = rowID.index(rowID.startIndex, offsetBy: 6)
        guard let monthValue = Int(rowID[..<monthEnd]) else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets month")
        }
        let separator = rowID[monthEnd]
        guard separator == "-" else {
            throw LocalFirstError.invalidLocalWrite("invalid zero_budgets row")
        }
        let categoryStart = rowID.index(after: monthEnd)
        let categoryID = String(rowID[categoryStart...])
        guard !categoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        return (monthValue, monthID(monthValue), categoryID)
    }
}
