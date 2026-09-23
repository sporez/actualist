import Foundation
import GRDB

struct BudgetTemplatePreparedPlan: Sendable {
    var compute: BudgetTemplateComputePlan
    var currentBudgeted: [String: Int]
    var currentGoals: [String: Int]
    var entriesByCategory: [String: [BudgetTemplateEntry]]
    var categoryIsIncome: [String: Bool]
    var isTracking: Bool
    var canWriteGoals: Bool
    var orphanGoalCategoryIDs: [String]
    var table: BudgetTable
    var columns: Set<String>
    var initialAvailableBudget: Int
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
        currentMonth: String? = nil,
        now: Date = Date()
    ) throws -> BudgetTemplateApplyPreview {
        try queue.read { db in
            try makeBudgetTemplateApplyPreview(
                command: command,
                month: month,
                currentMonth: currentMonth,
                now: now,
                db: db
            )
        }
    }

    /// Calculates both month-wide Apply modes while holding one SQLite read
    /// snapshot. Each scenario catches its own template validation failure.
    func previewBudgetTemplatePair(
        month: String,
        currentMonth: String? = nil,
        now: Date = Date()
    ) throws -> BudgetTemplateApplyPreviewPair {
        try queue.read { db in
            let fillEmpty = previewBudgetTemplateOutcome(
                command: .fillEmpty,
                month: month,
                currentMonth: currentMonth,
                now: now,
                db: db
            )
            let overwrite = previewBudgetTemplateOutcome(
                command: .overwrite,
                month: month,
                currentMonth: currentMonth,
                now: now,
                db: db
            )
            return BudgetTemplateApplyPreviewPair(fillEmpty: fillEmpty, overwrite: overwrite)
        }
    }

    private func previewBudgetTemplateOutcome(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String?,
        now: Date,
        db: Database
    ) -> BudgetTemplatePreviewOutcome {
        do {
            return .ready(
                try makeBudgetTemplateApplyPreview(
                    command: command,
                    month: month,
                    currentMonth: currentMonth,
                    now: now,
                    db: db
                )
            )
        } catch {
            return .failed(error.userFacingMessage ?? "The template preview could not be loaded.")
        }
    }

    private func makeBudgetTemplateApplyPreview(
        command: BudgetTemplateCommand,
        month: String,
        currentMonth: String?,
        now: Date,
        db: Database
    ) throws -> BudgetTemplateApplyPreview {
        let prepared = try budgetTemplatePlan(
            command: command,
            month: month,
            currentMonth: currentMonth,
            skipAvailableClamp: false,
            goalDefOverrides: [:],
            skipStaleCheck: false,
            db: db
        )
        let names = try templateCategoryNames(db: db)
        let currentValues = try categoryValues(through: month, db: db)
        let reviewRevision = try budgetTemplateReviewRevision(month: month, db: db)
        let currency = try budgetCurrency(db: db)
        let includedTrackingCategoryIDs: Set<String>
        if prepared.isTracking {
            let groups = try fetchCategoryGroups(categoryValues: currentValues, db: db)
            let firstIncomeGroupID = groups.first(where: \.isIncome)?.id
            includedTrackingCategoryIDs = Set(groups
                .filter { $0.isIncome ? $0.id == firstIncomeGroupID : $0.hidden != true }
                .flatMap { $0.categories.filter { $0.hidden != true }.map(\.id) })
        } else {
            includedTrackingCategoryIDs = []
        }
        let writesByCategory = Dictionary(
            uniqueKeysWithValues: prepared.compute.writes.map { ($0.categoryID, $0) }
        )
        var orderedIDs = prepared.compute.writes.map(\.categoryID)
        for categoryID in prepared.orphanGoalCategoryIDs where !orderedIDs.contains(categoryID) {
            orderedIDs.append(categoryID)
        }

        var categories: [BudgetTemplateApplyPreview.Category] = []
        var assigned = 0
        var released = 0
        var hasNonMoneyUpdates = false

        for categoryID in orderedIDs {
            let write = writesByCategory[categoryID]
            let current = prepared.currentBudgeted[categoryID] ?? 0
            let proposed = write?.amount ?? current
            let evaluatedDemand = prepared.compute.evaluatedDemandByCategory[categoryID] ?? 0
            let shortfall = prepared.compute.clampShortfallByCategory[categoryID] ?? 0
            let goalBefore = prepared.currentGoals[categoryID]
            let goalAfter = write?.goal
            let goalChanged = goalBefore != goalAfter
            let entries = prepared.entriesByCategory[categoryID] ?? []
            let isGoalOnly = isGoalOnly(entries)
            let isOrphanGoal = prepared.orphanGoalCategoryIDs.contains(categoryID)
            let isGoalOnlyUpdate = isGoalOnly && goalChanged || isOrphanGoal
            guard current != proposed || shortfall > 0 || goalChanged else {
                continue
            }

            let delta = try BudgetTemplateEngine.checkedSubtract(proposed, current)
            if delta >= 0 {
                assigned = try BudgetTemplateEngine.checkedAdd(assigned, delta)
            } else {
                released = try BudgetTemplateEngine.checkedAdd(
                    released,
                    try BudgetTemplateEngine.checkedSubtract(0, delta)
                )
            }
            hasNonMoneyUpdates = hasNonMoneyUpdates || goalChanged

            let beforeValue = currentValues[categoryID] ?? BudgetCategoryValue()
            let afterBalance = try BudgetFinancialCalculation.sum(
                [beforeValue.balance, delta],
                table: prepared.table
            )
            let metric: BudgetTemplateCategoryMetric
            if prepared.isTracking {
                if prepared.categoryIsIncome[categoryID] == true {
                    metric = BudgetTemplateCategoryMetric(
                        kind: .received,
                        before: beforeValue.spent,
                        after: beforeValue.spent
                    )
                } else {
                    metric = BudgetTemplateCategoryMetric(
                        kind: .balance,
                        before: beforeValue.balance,
                        after: afterBalance
                    )
                }
            } else {
                metric = BudgetTemplateCategoryMetric(
                    kind: .available,
                    before: beforeValue.balance,
                    after: afterBalance
                )
            }
            categories.append(BudgetTemplateApplyPreview.Category(
                categoryID: categoryID,
                name: names[categoryID] ?? categoryID,
                current: current,
                proposed: proposed,
                perTemplate: prepared.compute.contributions[categoryID]
                    ?? Array(repeating: 0, count: entries.count),
                drafts: BudgetTemplateDefinition.drafts(
                    from: entries,
                    now: now
                ) ?? [],
                evaluatedDemand: evaluatedDemand,
                shortfall: shortfall,
                isGoalOnlyUpdate: isGoalOnlyUpdate,
                goalBefore: goalBefore,
                goalAfter: goalAfter,
                metric: metric
            ))
        }

        let evaluatedDemand = prepared.compute.evaluatedDemand
        var netFundingRequired = 0
        for (categoryID, entries) in prepared.entriesByCategory where !isGoalOnly(entries) {
            let targetChange = try BudgetTemplateEngine.checkedSubtract(
                prepared.compute.evaluatedDemandByCategory[categoryID] ?? 0,
                prepared.currentBudgeted[categoryID] ?? 0
            )
            // Tracking income adds to Total Saved; expenses use it. Envelope
            // whole-month applies have no income categories in their scope.
            let cost = prepared.isTracking && prepared.categoryIsIncome[categoryID] == true
                ? try BudgetTemplateEngine.checkedSubtract(0, targetChange)
                : targetChange
            netFundingRequired = try BudgetTemplateEngine.checkedAdd(
                netFundingRequired,
                cost
            )
        }
        // To Budget / Total Saved is not subtracted here: it determines how
        // much of the requirement the apply can meet, not what was requested.
        let fundingRequired = max(0, netFundingRequired)
        var availableAfter = prepared.compute.leftover
        if prepared.isTracking {
            // The engine's remaining availability is an allocation input, not
            // tracking's displayed Total Saved. Project only the same visible
            // categories that trackingTotalSaved includes.
            availableAfter = prepared.initialAvailableBudget
            for write in prepared.compute.writes where includedTrackingCategoryIDs.contains(write.categoryID) {
                let delta = try BudgetTemplateEngine.checkedSubtract(
                    write.amount,
                    prepared.currentBudgeted[write.categoryID] ?? 0
                )
                let effect = prepared.categoryIsIncome[write.categoryID] == true
                    ? delta
                    : try BudgetTemplateEngine.checkedSubtract(0, delta)
                availableAfter = try BudgetFinancialCalculation.sum(
                    [availableAfter, effect], table: .tracking
                )
            }
        }
        return BudgetTemplateApplyPreview(
            modeIdentity: reviewRevision.modeIdentity,
            assigned: assigned,
            leftover: prepared.compute.leftover,
            isTrackingBudget: prepared.isTracking,
            currency: currency,
            categories: categories,
            released: released,
            evaluatedDemand: evaluatedDemand,
            fundingRequired: fundingRequired,
            stillNeeded: prepared.compute.clampShortfall,
            availableBefore: prepared.initialAvailableBudget,
            availableAfter: availableAfter,
            hasNonMoneyUpdates: hasNonMoneyUpdates,
            hasEligibleTemplates: !prepared.entriesByCategory.isEmpty,
            reviewRevision: reviewRevision
        )
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
        let initialAvailableBudget = try isTracking
            ? trackingTotalSaved(month: monthID(monthValue), db: db)
            : envelopeToBudget(month: monthID(monthValue), db: db)
        var availableBudget = initialAvailableBudget
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
            currentGoals: existingGoals,
            entriesByCategory: categoryTemplates,
            categoryIsIncome: categoryIsIncome,
            isTracking: isTracking,
            canWriteGoals: canWriteGoals,
            orphanGoalCategoryIDs: orphanGoalCategoryIDs,
            table: table,
            columns: columns,
            initialAvailableBudget: initialAvailableBudget
        )
    }
}
