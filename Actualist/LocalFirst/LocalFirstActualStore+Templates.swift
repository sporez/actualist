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
        let messages = try await database.setCategoryTemplateMessages(
            categoryID: categoryID,
            goalDefJSON: goalDefJSON,
            builder: &builder
        )
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
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
        return try await database.dryRunCategoryTemplate(
            categoryID: categoryID,
            goalDefJSON: goalDefJSON,
            month: month
        )
    }

    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot {
        let database = try requireDatabase(for: budgetID)
        return try await database.categoryTemplateEditorSnapshot(categoryID: categoryID)
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        let database = try requireDatabase(for: budgetID)
        return try await database.previewBudgetTemplate(
            command: command,
            month: month
        )
    }
}
