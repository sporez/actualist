import Foundation
import Observation

struct BudgetTemplatesBrowserSection: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case group(String)
        case hidden
    }

    var kind: Kind
    var title: String
    var rows: [BudgetTemplatesBrowserRow]

    var id: String {
        switch kind {
        case .group(let groupID):
            "group-\(groupID)"
        case .hidden:
            "hidden"
        }
    }
}

struct BudgetTemplatesBrowserRow: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
}

@MainActor
@Observable
final class BudgetTemplatesBrowserViewModel {
    private(set) var snapshot = BudgetTemplateBrowserSnapshot.empty
    private(set) var isLoading = false
    var errorMessage: String?
    var isPrivacyModeEnabled = false
    var isHiddenSectionExpanded = false

    private var loadGeneration = 0
    private var hasBudget = false

    var hasTemplates: Bool {
        snapshot.categories.contains(where: \.hasDefinition)
    }

    var canAdd: Bool {
        hasBudget
    }

    var visibleSections: [BudgetTemplatesBrowserSection] {
        sections(
            from: snapshot.categories.filter { $0.hasDefinition && !$0.isEffectivelyHidden }
        )
    }

    var hiddenSection: BudgetTemplatesBrowserSection? {
        let rows = snapshot.categories
            .filter { $0.hasDefinition && $0.isEffectivelyHidden }
            .map(makeRow)
        guard !rows.isEmpty else {
            return nil
        }
        return BudgetTemplatesBrowserSection(kind: .hidden, title: "Hidden", rows: rows)
    }

    var pickerVisibleSections: [BudgetTemplatesBrowserSection] {
        sections(
            from: snapshot.categories.filter { !$0.hasDefinition && !$0.isEffectivelyHidden }
        )
    }

    var pickerHiddenSection: BudgetTemplatesBrowserSection? {
        let rows = snapshot.categories
            .filter { !$0.hasDefinition && $0.isEffectivelyHidden }
            .map(makeRow)
        guard !rows.isEmpty else {
            return nil
        }
        return BudgetTemplatesBrowserSection(kind: .hidden, title: "Hidden", rows: rows)
    }

    var pickerIsEmpty: Bool {
        pickerVisibleSections.isEmpty && pickerHiddenSection == nil
    }

    var emptyTitle: String {
        hasBudget ? "No Templates" : "No Budget"
    }

    var emptyDescription: String {
        hasBudget
            ? "Add a template to a category. Categories with templates appear here."
            : "Select a budget to manage templates."
    }

    func load(repository: any BudgetRepositoryProtocol, budgetID: String?) async {
        loadGeneration += 1
        let requestGeneration = loadGeneration
        guard let budgetID, !budgetID.isEmpty else {
            hasBudget = false
            snapshot = .empty
            isLoading = false
            errorMessage = nil
            return
        }

        hasBudget = true
        if snapshot.categories.isEmpty {
            isLoading = true
        }
        do {
            let loaded = try await repository.categoryTemplateBrowserSnapshot(budgetID: budgetID)
            guard requestGeneration == loadGeneration else {
                return
            }
            snapshot = loaded
            errorMessage = nil
        } catch {
            guard requestGeneration == loadGeneration else {
                return
            }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func toggleHiddenSection() {
        isHiddenSectionExpanded.toggle()
    }

    func editorTarget(for categoryID: String) -> BudgetTemplateEditorTarget? {
        guard let category = snapshot.categories.first(where: { $0.id == categoryID }) else {
            return nil
        }
        return BudgetTemplateEditorTarget(
            categoryID: category.id,
            categoryName: category.name.actualistCategoryNameParts.name,
            month: snapshot.month
        )
    }

    private func sections(
        from categories: [BudgetTemplateBrowserCategory]
    ) -> [BudgetTemplatesBrowserSection] {
        var sections: [BudgetTemplatesBrowserSection] = []
        var indexByGroup: [String: Int] = [:]
        for category in categories {
            let row = makeRow(category)
            if let index = indexByGroup[category.groupID] {
                sections[index].rows.append(row)
                continue
            }
            indexByGroup[category.groupID] = sections.count
            sections.append(
                BudgetTemplatesBrowserSection(
                    kind: .group(category.groupID),
                    title: category.groupName,
                    rows: [row]
                )
            )
        }
        return sections
    }

    private func makeRow(_ category: BudgetTemplateBrowserCategory) -> BudgetTemplatesBrowserRow {
        BudgetTemplatesBrowserRow(
            id: category.id,
            title: category.name.actualistCategoryNameParts.name,
            subtitle: BudgetTemplateSummary.line(
                drafts: category.drafts,
                currency: snapshot.currency,
                randomized: isPrivacyModeEnabled,
                seed: category.id
            )
        )
    }
}
