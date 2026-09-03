import Foundation
import GRDB

struct BudgetTemplatePreparedPlan: Sendable {
    var compute: BudgetTemplateComputePlan
    var currentBudgeted: [String: Int]
    var entriesByCategory: [String: [BudgetTemplateEntry]]
    var isTracking: Bool
    var canWriteGoals: Bool
    var orphanGoalCategoryIDs: [String]
    var table: BudgetTable
    var columns: Set<String>
}

extension BudgetDatabase {
    func dryRunCategoryTemplate(
        categoryID: String,
        goalDefJSON: String?,
        month: String,
        currentMonth: String? = nil
    ) throws -> BudgetTemplateCategoryDryRun {
        let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        let templateCount: Int
        switch BudgetTemplateDefinition.parseEntries(from: goalDefJSON) {
        case .failure:
            throw LocalFirstError.unsupportedTemplate(
                BudgetTemplateCategoryLock.Reason.unsupportedType.testerFacingReason
            )
        case .success(let entries):
            templateCount = entries.count
        }
        if trimmed.isEmpty {
            return BudgetTemplateCategoryDryRun(
                budgeted: 0,
                perTemplate: Array(repeating: 0, count: templateCount)
            )
        }
        let zeros = BudgetTemplateCategoryDryRun(
            budgeted: 0,
            perTemplate: Array(repeating: 0, count: templateCount)
        )
        guard let json = goalDefJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !json.isEmpty, json != "null", json != "[]" else {
            return zeros
        }

        return try queue.read { db in
            let liveIDs = try templateCategoryIDsInCategoryOrder(db: db)
            guard liveIDs.contains(trimmed) else {
                return zeros
            }
            let prepared = try budgetTemplatePlan(
                command: .category(trimmed),
                month: month,
                currentMonth: currentMonth,
                skipAvailableClamp: true,
                goalDefOverrides: [trimmed: json],
                skipStaleCheck: true,
                db: db
            )
            let write = prepared.compute.writes.first { $0.categoryID == trimmed }
            let contributions = prepared.compute.contributions[trimmed]
                ?? Array(repeating: 0, count: templateCount)
            let perTemplate: [Int]
            if contributions.count == templateCount {
                perTemplate = contributions
            } else {
                perTemplate = Array(repeating: 0, count: templateCount)
            }
            return BudgetTemplateCategoryDryRun(
                budgeted: write?.amount ?? 0,
                perTemplate: perTemplate
            )
        }
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String? = nil
    ) throws -> BudgetTemplateApplyPreview {
        try queue.read { db in
            let prepared = try budgetTemplatePlan(
                command: command,
                month: month,
                currentMonth: currentMonth,
                skipAvailableClamp: false,
                goalDefOverrides: [:],
                skipStaleCheck: false,
                db: db
            )
            var categories: [BudgetTemplateApplyPreview.Category] = []
            for write in prepared.compute.writes {
                let current = prepared.currentBudgeted[write.categoryID] ?? 0
                guard write.amount != current else { continue }
                let entries = prepared.entriesByCategory[write.categoryID] ?? []
                categories.append(
                    BudgetTemplateApplyPreview.Category(
                        categoryID: write.categoryID,
                        current: current,
                        proposed: write.amount,
                        perTemplate: prepared.compute.contributions[write.categoryID]
                            ?? Array(repeating: 0, count: entries.count)
                    )
                )
            }
            return BudgetTemplateApplyPreview(
                assigned: categories.reduce(0) { $0 + $1.proposed },
                leftover: prepared.compute.leftover,
                isTrackingBudget: prepared.isTracking,
                categories: categories
            )
        }
    }

    func budgetTemplatePlan(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String?,
        skipAvailableClamp: Bool,
        goalDefOverrides: [String: String],
        skipStaleCheck: Bool,
        db: Database
    ) throws -> BudgetTemplatePreparedPlan {
        let monthValue = try Self.actualMonthValue(month)
        let currentMonthValue = try Self.actualMonthValue(
            currentMonth ?? BudgetTemplateCalendar.currentMonthID()
        )
        let templateEngine = BudgetTemplateEngine(currency: try budgetCurrency(db: db))
        let table = try budgetTable(db: db)
        let columns = try requiredColumns(
            table: table.rawValue,
            required: ["month", "category", "amount"],
            db: db
        )
        let canWriteGoals = columns.contains("goal")
        var goalDefsRaw = try readCategoryGoalDefsRaw(db: db)
        for (categoryID, json) in goalDefOverrides {
            goalDefsRaw[categoryID] = json
        }
        let categoryNames = try templateCategoryNames(db: db)
        let categoryIsIncome = try templateCategoryIsIncomeByID(db: db)
        let isTracking = table == .tracking
        let targeted = Set(
            command.categoryIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let scope: [String]
        if targeted.isEmpty {
            scope = try templateCategoryIDsInBudgetOrder(
                db: db,
                includeIncome: isTracking,
                includeHidden: false
            )
        } else {
            scope = try templateCategoryIDsInCategoryOrder(db: db)
                .filter { targeted.contains($0) }
        }

        if !skipStaleCheck {
            let staleSource = goalDefsRaw.filter { scope.contains($0.key) && goalDefOverrides[$0.key] == nil }
            let stale = try staleNoteManagedTemplateCategories(
                goalDefsRaw: staleSource,
                db: db
            )
            if !stale.isEmpty {
                let described = stale
                    .map { (categoryNames[$0.categoryID] ?? $0.categoryID) + " — " + $0.reason }
                    .sorted()
                throw LocalFirstError.unsupportedTemplate(
                    "note-managed template definition(s) are stale relative to their category notes and were not applied: \(described.joined(separator: "; ")). Open the budget in Actual and apply templates once to refresh the stored definitions."
                )
            }
        }

        let force = command.mode == .overwrite || !targeted.isEmpty
        let currentBudgets = try categoryBudgets(month: monthID(monthValue), db: db)
        let existingGoals = canWriteGoals
            ? try categoryGoals(month: monthID(monthValue), db: db)
            : [:]

        var unsupported: [String] = []
        var categoryTemplates: [String: [BudgetTemplateEntry]] = [:]
        var orphanGoalCategoryIDs: [String] = []
        var availableBudget = try isTracking
            ? trackingTotalSaved(month: monthID(monthValue), db: db)
            : envelopeToBudget(month: monthID(monthValue), db: db)
        var incomeCatalog = try templateIncomeCatalog(db: db)
        let activeSchedules = try templateActiveSchedules(db: db)
        incomeCatalog.activeScheduleIDs = activeSchedules.ids
        incomeCatalog.activeScheduleNames = activeSchedules.names
        for categoryID in scope {
            let currentBudgeted = currentBudgets[categoryID]?.budgeted ?? 0
            guard let json = goalDefsRaw[categoryID] else {
                if existingGoals[categoryID] != nil {
                    orphanGoalCategoryIDs.append(categoryID)
                }
                continue
            }
            guard force || currentBudgeted == 0 else { continue }

            do {
                if let entries = try templateEngine.decodeSupportedEntries(json: json) {
                    try templateEngine.validate(entries, for: monthValue)
                    try templateEngine.validatePercentageSources(
                        entries,
                        monthSources: incomeCatalog
                    )
                    try templateEngine.validateByScheduleAndSpend(
                        entries,
                        monthValue: monthValue,
                        activeScheduleNames: incomeCatalog.activeScheduleNames,
                        activeScheduleIDs: incomeCatalog.activeScheduleIDs
                    )
                    categoryTemplates[categoryID] = entries
                    if !isGoalOnly(entries) {
                        availableBudget = try BudgetTemplateEngine.checkedAdd(
                            availableBudget,
                            currentBudgeted
                        )
                    }
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

        let (categories, monthSources) = try templateEngineInputs(
            categoryTemplates: categoryTemplates,
            monthValue: monthValue,
            categoryIsIncome: categoryIsIncome,
            previouslyBudgetedByCategory: currentBudgets.mapValues(\.budgeted),
            isTrackingBudget: isTracking,
            db: db
        )
        let compute = try templateEngine.computePlan(
            categories: categories,
            orderedCategoryIDs: scope.filter { categories[$0] != nil },
            monthValue: monthValue,
            availableBudget: availableBudget,
            monthSources: monthSources,
            currentMonthValue: currentMonthValue,
            skipAvailableClamp: skipAvailableClamp
        )
        if compute.writes.contains(where: { $0.longGoal == 1 }), !canWriteGoals {
            throw LocalFirstError.unsupportedTemplate(
                "goal writes require \(table.rawValue).goal"
            )
        }
        return BudgetTemplatePreparedPlan(
            compute: compute,
            currentBudgeted: currentBudgets.mapValues(\.budgeted),
            entriesByCategory: categoryTemplates,
            isTracking: isTracking,
            canWriteGoals: canWriteGoals,
            orphanGoalCategoryIDs: orphanGoalCategoryIDs,
            table: table,
            columns: columns
        )
    }
}
