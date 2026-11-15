import Foundation

extension LocalFirstActualStore {
    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let goalDefJSON: String?
        if drafts.isEmpty {
            goalDefJSON = nil
        } else {
            goalDefJSON = try BudgetTemplateDefinition.encode(drafts)
        }
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await TemplateAuthoringSQL.setCategoryTemplateMessages(
            categoryID: categoryID,
            goalDefJSON: goalDefJSON,
            builder: &builder,
            in: database
        )
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun {
        let database = try requireDatabase(for: budgetID)
        let goalDefJSON: String?
        if drafts.isEmpty {
            goalDefJSON = nil
        } else {
            goalDefJSON = try BudgetTemplateDefinition.encode(drafts)
        }
        return try await TemplatePreviewSQL.dryRunCategoryTemplate(
            categoryID: categoryID,
            goalDefJSON: goalDefJSON,
            month: month,
            in: database
        )
    }

    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot {
        let database = try requireDatabase(for: budgetID)
        return try await TemplateAuthoringSQL.categoryTemplateEditorSnapshot(categoryID: categoryID, in: database)
    }

    func categoryTemplateBrowserSnapshot(
        budgetID: String
    ) async throws -> BudgetTemplateBrowserSnapshot {
        let month = loadedBudgetMonthsByBudget[budgetID]?.selectedMonth
        if var cached = templateBrowserByBudget[budgetID] {
            if let month {
                cached.month = month
            }
            return cached
        }
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let revision = cachePublicationRevision
        var snapshot = try await TemplateAuthoringSQL.categoryTemplateBrowserSnapshot(in: database)
        #if DEBUG
        await testSeams?.readPublicationHook?(.templateBrowser)
        #endif
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if let month {
            snapshot.month = month
        }
        if revision == cachePublicationRevision {
            templateBrowserByBudget[budgetID] = snapshot
        }
        return snapshot
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        let database = try requireDatabase(for: budgetID)
        return try await TemplatePreviewSQL.previewBudgetTemplate(
            command: command,
            month: month,
            in: database
        )
    }

    func previewBudgetTemplatePair(
        budgetID: String,
        month: String,
        excluding: Set<String>
    ) async throws -> BudgetTemplateApplyPreviewPair {
        let database = try requireDatabase(for: budgetID)
        return try await TemplatePreviewSQL.previewBudgetTemplatePair(month: month, excluding: excluding, in: database)
    }

    func applyReviewedBudgetTemplateAndRefresh(
        reviewRevision: BudgetTemplateReviewRevision,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard reviewRevision.month == month else {
            throw LocalFirstError.budgetTemplateReviewStale
        }
        return try await applyBudgetTemplateAndRefresh(
            reviewRevision: reviewRevision,
            expectedMode: nil,
            command: command,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didApply: didApply
        )
    }
}
