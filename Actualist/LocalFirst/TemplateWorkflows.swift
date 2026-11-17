import Foundation

/// Template authoring on the store: the editor, browser and dry-run reads, the
/// template write with the reload that follows, and the Apply Templates
/// previews. The store owns it and keeps the browser snapshot cache.
@MainActor
final class TemplateWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        let database = try store.requireDatabase(for: budgetID)
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
        try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun {
        let database = try store.requireDatabase(for: budgetID)
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
        let database = try store.requireDatabase(for: budgetID)
        return try await TemplateAuthoringSQL.categoryTemplateEditorSnapshot(categoryID: categoryID, in: database)
    }

    func categoryTemplateBrowserSnapshot(
        budgetID: String
    ) async throws -> BudgetTemplateBrowserSnapshot {
        let month = store.loadedBudgetMonthsByBudget[budgetID]?.selectedMonth
        if var cached = store.templateBrowserByBudget[budgetID] {
            if let month {
                cached.month = month
            }
            return cached
        }
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let revision = store.cachePublicationRevision
        var snapshot = try await TemplateAuthoringSQL.categoryTemplateBrowserSnapshot(in: database)
        #if DEBUG
        await store.testSeams?.readPublicationHook?(.templateBrowser)
        #endif
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if let month {
            snapshot.month = month
        }
        if revision == store.cachePublicationRevision {
            store.templateBrowserByBudget[budgetID] = snapshot
        }
        return snapshot
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        let database = try store.requireDatabase(for: budgetID)
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
        let database = try store.requireDatabase(for: budgetID)
        return try await TemplatePreviewSQL.previewBudgetTemplatePair(month: month, excluding: excluding, in: database)
    }
}

extension TemplateWorkflows: BudgetTemplateRepositoryProtocol { }
