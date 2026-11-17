import Foundation
import Testing
@testable import Actualist

@Suite("Budget templates browser view model")
@MainActor
struct BudgetTemplatesBrowserViewModelTests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!

    @Test func groupsVisibleTemplatesAndCollapsesHidden() async throws {
        let viewModel = BudgetTemplatesBrowserViewModel()
        await viewModel.load(
            repository: BrowserTemplateRepository(snapshot: makeSnapshot()),
            budgetID: "budget-1"
        )

        #expect(viewModel.hasTemplates)
        #expect(viewModel.canAdd)
        #expect(viewModel.visibleSections.map(\.title) == ["Income", "Everyday", "Bills"])
        #expect(viewModel.visibleSections.map { $0.rows.map(\.id) } == [
            ["salary"],
            ["groceries"],
            ["rent"],
        ])
        #expect(viewModel.visibleSections[1].rows[0].subtitle == "\(BudgetCurrency.usd.formatted(40_000))/mo")
        #expect(viewModel.hiddenSection?.rows.map(\.id) == ["hidden-cat", "archived"])
        #expect(!viewModel.isHiddenSectionExpanded)

        viewModel.toggleHiddenSection()
        #expect(viewModel.isHiddenSectionExpanded)
    }

    @Test func pickerListsCategoriesWithoutTemplatesAndHidesTrailing() async throws {
        let viewModel = BudgetTemplatesBrowserViewModel()
        await viewModel.load(
            repository: BrowserTemplateRepository(snapshot: makeSnapshot()),
            budgetID: "budget-1"
        )

        #expect(viewModel.pickerVisibleSections.map(\.title) == ["Everyday", "Bills"])
        #expect(viewModel.pickerVisibleSections.map { $0.rows.map(\.id) } == [
            ["spare"],
            ["utilities"],
        ])
        #expect(viewModel.pickerHiddenSection?.rows.map(\.id) == ["spare-hidden"])
        #expect(!viewModel.pickerIsEmpty)
        #expect(viewModel.editorTarget(for: "spare")?.categoryName == "Spare")
        #expect(viewModel.editorTarget(for: "spare")?.month == "2026-09")
    }

    @Test func privacyRandomizesSummaryAmounts() async throws {
        let viewModel = BudgetTemplatesBrowserViewModel()
        viewModel.isPrivacyModeEnabled = true
        await viewModel.load(
            repository: BrowserTemplateRepository(snapshot: makeSnapshot()),
            budgetID: "budget-1"
        )
        let subtitle = try #require(viewModel.visibleSections[1].rows.first?.subtitle)
        let expected = PrivacyDisplay.money(40_000, seed: "groceries-0", currency: .usd)
        #expect(subtitle == "\(expected)/mo")
        if BudgetCurrency.usd.formatted(40_000) != expected {
            #expect(!subtitle.contains(BudgetCurrency.usd.formatted(40_000)))
        }
    }

    @Test func emptyBudgetAndMissingBudget() async throws {
        let viewModel = BudgetTemplatesBrowserViewModel()
        await viewModel.load(
            repository: BrowserTemplateRepository(
                snapshot: BudgetTemplateBrowserSnapshot(
                    categories: [
                        makeCategory(
                            id: "spare",
                            name: "Spare",
                            groupID: "group",
                            groupName: "Everyday",
                            hasDefinition: false
                        )
                    ],
                    currency: .usd,
                    month: "2026-09"
                )
            ),
            budgetID: "budget-1"
        )
        #expect(!viewModel.hasTemplates)
        #expect(viewModel.emptyTitle == "No Templates")
        #expect(viewModel.canAdd)
        #expect(viewModel.pickerVisibleSections.first?.rows.map(\.id) == ["spare"])

        await viewModel.load(repository: BrowserTemplateRepository(snapshot: .empty), budgetID: nil)
        #expect(!viewModel.hasTemplates)
        #expect(viewModel.emptyTitle == "No Budget")
        #expect(!viewModel.canAdd)
    }

    @Test func pickingALockedCategoryStillOpensTheEditorTarget() async throws {
        var snapshot = makeSnapshot()
        snapshot.categories.append(
            makeCategory(
                id: "locked",
                name: "Locked",
                groupID: "group",
                groupName: "Everyday",
                hasDefinition: false,
                lock: .readOnly(.missingColumns)
            )
        )
        let viewModel = BudgetTemplatesBrowserViewModel()
        await viewModel.load(
            repository: BrowserTemplateRepository(snapshot: snapshot),
            budgetID: "budget-1"
        )
        let target = try #require(viewModel.editorTarget(for: "locked"))
        #expect(target.categoryID == "locked")
        #expect(target.categoryName == "Locked")
        #expect(viewModel.pickerVisibleSections.flatMap(\.rows).map(\.id).contains("locked"))
    }

    private func makeSnapshot() -> BudgetTemplateBrowserSnapshot {
        BudgetTemplateBrowserSnapshot(
            categories: [
                makeCategory(
                    id: "salary",
                    name: "Salary",
                    groupID: "income",
                    groupName: "Income",
                    isIncome: true,
                    drafts: [.monthlyFixed(amount: 1000, now: now)]
                ),
                makeCategory(
                    id: "groceries",
                    name: "Groceries",
                    groupID: "group",
                    groupName: "Everyday",
                    drafts: [.monthlyFixed(amount: 400, now: now)]
                ),
                makeCategory(
                    id: "spare",
                    name: "Spare",
                    groupID: "group",
                    groupName: "Everyday",
                    hasDefinition: false
                ),
                makeCategory(
                    id: "hidden-cat",
                    name: "Old Stuff",
                    groupID: "group",
                    groupName: "Everyday",
                    isEffectivelyHidden: true,
                    drafts: [.remainder()]
                ),
                makeCategory(
                    id: "rent",
                    name: "Rent",
                    groupID: "bills",
                    groupName: "Bills",
                    drafts: [.monthlyFixed(amount: 200, now: now)]
                ),
                makeCategory(
                    id: "utilities",
                    name: "Utilities",
                    groupID: "bills",
                    groupName: "Bills",
                    hasDefinition: false
                ),
                makeCategory(
                    id: "archived",
                    name: "Archived",
                    groupID: "archive",
                    groupName: "Archive",
                    isEffectivelyHidden: true,
                    drafts: [.goal()]
                ),
                makeCategory(
                    id: "spare-hidden",
                    name: "Spare Hidden",
                    groupID: "archive",
                    groupName: "Archive",
                    isEffectivelyHidden: true,
                    hasDefinition: false
                ),
            ],
            currency: .usd,
            month: "2026-09"
        )
    }

    private func makeCategory(
        id: String,
        name: String,
        groupID: String,
        groupName: String,
        isIncome: Bool = false,
        isEffectivelyHidden: Bool = false,
        hasDefinition: Bool = true,
        drafts: [BudgetTemplateDraft] = [],
        lock: BudgetTemplateCategoryLock = .editable
    ) -> BudgetTemplateBrowserCategory {
        BudgetTemplateBrowserCategory(
            id: id,
            name: name,
            groupID: groupID,
            groupName: groupName,
            isIncome: isIncome,
            isEffectivelyHidden: isEffectivelyHidden,
            hasDefinition: hasDefinition,
            drafts: drafts,
            lock: lock
        )
    }
}

private actor BrowserTemplateRepository: BudgetTemplateRepositoryProtocol {
    var snapshot: BudgetTemplateBrowserSnapshot

    init(snapshot: BudgetTemplateBrowserSnapshot) {
        self.snapshot = snapshot
    }

    func categoryTemplateBrowserSnapshot(
        budgetID: String
    ) async throws -> BudgetTemplateBrowserSnapshot {
        snapshot
    }

    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun {
        throw LocalFirstError.unsupportedWrite
    }

    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot {
        throw LocalFirstError.unsupportedWrite
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        throw LocalFirstError.unsupportedWrite
    }

    func previewBudgetTemplatePair(
        budgetID: String,
        month: String,
        excluding: Set<String>
    ) async throws -> BudgetTemplateApplyPreviewPair {
        throw LocalFirstError.unsupportedWrite
    }
}
