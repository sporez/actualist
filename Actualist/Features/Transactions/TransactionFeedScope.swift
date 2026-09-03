import SwiftUI
import Observation

struct CategoryMonthDetails: Identifiable, Hashable {
    let category: BudgetMonthCategory
    let month: String

    var id: String { "\(month)|\(category.id)" }
    var budgetedAmount: Int { category.budgeted }
    var spentAmount: Int { -category.spent }
    var remainingAmount: Int { category.balance }

    var monthTitle: String {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let monthNumber = Int(parts[1]),
              let date = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: year, month: monthNumber, day: 1)
              ) else {
            return month
        }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}

@MainActor
@Observable
final class CategoryMonthDetailsViewModel {
    var details: CategoryMonthDetails
    var isCarryoverEnabled: Bool
    var isUpdatingCarryover = false
    var carryoverErrorMessage: String?
    private(set) var categoryNotePresentation: ActualNotePresentation?
    private(set) var templateDoor: BudgetTemplateDoorRow?
    private(set) var isTrackingBudget = false

    private var noteLoadGeneration = 0
    private var templateDoorGeneration = 0

    init(details: CategoryMonthDetails) {
        self.details = details
        self.isCarryoverEnabled = details.category.carryover
    }

    func refresh(using appState: AppState) async {
        guard !isUpdatingCarryover,
              let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.budgetRepository

        await refresh(budgetID: budgetID, repository: repository)
        await refreshNote(using: appState)
        await refreshTemplateDoor(using: appState)
    }

    func refreshTemplateDoor(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            templateDoor = nil
            return
        }
        await loadTemplateDoor(
            budgetID: budgetID,
            isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
            currency: appState.localFirstStore.budgetCurrency(budgetID: budgetID),
            repository: appState.budgetRepository
        )
    }

    func loadTemplateDoor(
        budgetID: String,
        isPrivacyModeEnabled: Bool,
        currency: BudgetCurrency,
        repository: any BudgetRepositoryProtocol
    ) async {
        templateDoorGeneration += 1
        let requestGeneration = templateDoorGeneration
        if details.category.isIncome && !isTrackingBudget {
            templateDoor = nil
            return
        }
        templateDoor = .placeholder(hasDefinition: details.category.hasTemplateDefinition)
        do {
            let snapshot = try await repository.categoryTemplateEditorSnapshot(
                categoryID: details.category.id,
                budgetID: budgetID
            )
            guard requestGeneration == templateDoorGeneration,
                  details.category.id == snapshot.categoryID else {
                return
            }
            templateDoor = .make(
                snapshot: snapshot,
                currency: currency,
                randomized: isPrivacyModeEnabled
            )
        } catch {
            guard requestGeneration == templateDoorGeneration else {
                return
            }
            templateDoor = .placeholder(hasDefinition: details.category.hasTemplateDefinition)
        }
    }

    func refreshNote(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            categoryNotePresentation = nil
            return
        }
        await loadCategoryNote(
            budgetID: budgetID,
            isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
            repository: appState.localFirstStore
        )
    }

    func loadCategoryNote(
        budgetID: String,
        isPrivacyModeEnabled: Bool,
        repository: any EntityNotesRepositoryProtocol
    ) async {
        noteLoadGeneration += 1
        let requestGeneration = noteLoadGeneration
        let categoryID = details.category.id

        guard !isPrivacyModeEnabled,
              details.category.hasUserNote,
              let target = ActualNoteTarget.category(
                id: categoryID,
                title: details.category.name
              ) else {
            categoryNotePresentation = nil
            return
        }

        do {
            let note = try await repository.entityNote(target: target, budgetID: budgetID)
            guard requestGeneration == noteLoadGeneration,
                  details.category.id == categoryID else {
                return
            }
            categoryNotePresentation = ActualNotePresentation(userBody: note.displayText)
        } catch {
            guard requestGeneration == noteLoadGeneration else {
                return
            }
            categoryNotePresentation = nil
        }
    }

    func refresh(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        do {
            let loaded = try await repository.budgetMonth(
                budgetID: budgetID,
                selectedMonth: details.month
            )
            apply(loaded)
        } catch {
            // Keep showing the cached summary.
        }
    }

    func setCarryover(_ enabled: Bool, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.budgetRepository

        await setCarryover(enabled, budgetID: budgetID, repository: repository)
    }

    func setCarryover(
        _ enabled: Bool,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        guard !isUpdatingCarryover, enabled != isCarryoverEnabled else {
            return
        }

        let previousValue = isCarryoverEnabled
        isCarryoverEnabled = enabled
        isUpdatingCarryover = true
        carryoverErrorMessage = nil

        do {
            let loaded = try await repository.setCategoryCarryoverAndRefresh(
                categoryID: details.category.id,
                carryover: enabled,
                budgetID: budgetID,
                startMonth: details.month
            ) {}
            apply(loaded)
        } catch {
            isCarryoverEnabled = previousValue
            carryoverErrorMessage = error.localizedDescription
        }

        isUpdatingCarryover = false
    }

    private func apply(_ loaded: LoadedBudgetMonth) {
        guard let category = loaded.month.categoryGroups
            .flatMap(\.categories)
            .first(where: { $0.id == details.category.id }) else {
            return
        }

        details = CategoryMonthDetails(category: category, month: details.month)
        isCarryoverEnabled = category.carryover
        isTrackingBudget = loaded.isTrackingBudget
    }
}

struct CategoryMonthDetailsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: CategoryMonthDetailsViewModel
    @State private var templateEditorTarget: BudgetTemplateEditorTarget?

    init(details: CategoryMonthDetails) {
        _viewModel = State(initialValue: CategoryMonthDetailsViewModel(details: details))
    }

    var body: some View {
        NavigationStack {
            AccountTransactionsView(
                scope: .category(viewModel.details),
                onChanged: {
                    Task { await viewModel.refresh(using: appState) }
                },
                categoryCarryoverIsEnabled: viewModel.isCarryoverEnabled,
                categoryNotePresentation: appState.settings.randomizedDisplayValuesEnabled
                    ? nil
                    : viewModel.categoryNotePresentation,
                categoryCarryoverIsUpdating: viewModel.isUpdatingCarryover,
                canEditCategoryCarryover: true,
                categoryCarryoverErrorMessage: viewModel.carryoverErrorMessage,
                onCategoryCarryoverChanged: { enabled in
                    Task { await viewModel.setCarryover(enabled, using: appState) }
                },
                templateDoor: viewModel.templateDoor,
                onOpenTemplates: {
                    templateEditorTarget = BudgetTemplateEditorTarget(
                        categoryID: viewModel.details.category.id,
                        categoryName: viewModel.details.category.name.actualistCategoryNameParts.name,
                        month: viewModel.details.month
                    )
                }
            )
        }
        .task { await viewModel.refresh(using: appState) }
        .onChange(of: appState.localDataRevision) {
            Task { await viewModel.refresh(using: appState) }
        }
        .onChange(of: appState.settings.randomizedDisplayValuesEnabled) {
            Task {
                await viewModel.refreshNote(using: appState)
                await viewModel.refreshTemplateDoor(using: appState)
            }
        }
        .sheet(item: $templateEditorTarget) { target in
            BudgetTemplateEditorView(target: target) {
                Task { await viewModel.refresh(using: appState) }
            }
            .environment(appState)
            .appSwitcherPrivacyProtected()
        }
        .presentationDetents([.large])
        .appSwitcherPrivacyAwareDragIndicator()
    }
}

enum TransactionFeedScope: Hashable {
    case account(ActualAccount)
    case spending
    case category(CategoryMonthDetails)

    var title: String {
        switch self {
        case .account(let account): account.name
        case .spending: "Spending"
        case .category(let details): details.category.name
        }
    }

    var account: ActualAccount? {
        switch self {
        case .account(let account): account
        case .spending, .category: nil
        }
    }

    var showsSummaryHeader: Bool {
        switch self {
        case .account, .category:
            true
        case .spending:
            false
        }
    }

    var refreshTargetDescription: String {
        switch self {
        case .account: "this account"
        case .spending: "Spending"
        case .category: "this category"
        }
    }

    var categoryDetails: CategoryMonthDetails? {
        guard case .category(let details) = self else { return nil }
        return details
    }

    var prefilledCategoryName: String? {
        categoryDetails?.category.name
    }

    var showsAccountNames: Bool {
        if case .account = self { return false }
        return true
    }
}
