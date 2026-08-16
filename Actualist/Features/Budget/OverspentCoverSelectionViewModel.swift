import Foundation
import Observation

@MainActor
@Observable
final class OverspentCoverSelectionViewModel {
    private let selectionWorkflow = OverspentCoverSelectionWorkflow()
    let moveMoneyWorkflow = BudgetMoveMoneyWorkflow()

    private(set) var coverMonth: LoadedBudgetMonth?

    private var errorMessageValue: String?

    var errorMessage: String? {
        errorMessageValue ?? moveMoneyWorkflow.errorMessage
    }

    var isCovering: Bool {
        selectionWorkflow.isSubmitting
    }

    var isBusyCovering: Bool {
        selectionWorkflow.isSubmitting || moveMoneyWorkflow.isSubmitting
    }

    var isSingleCoverPresented: Bool {
        moveMoneyWorkflow.isPresented
    }

    var isSelecting: Bool {
        selectionWorkflow.isSelecting
    }

    var selectedCategoryIDs: Set<String> {
        selectionWorkflow.selectedCategoryIDs
    }

    init(cachedMonth: LoadedBudgetMonth? = nil) {
        guard let cachedMonth else {
            return
        }
        apply(cachedMonth)
    }

    func options(includeCarryover: Bool) -> [BudgetOverspentCategoryOption] {
        guard let coverMonth else {
            return []
        }

        return Self.overspentOptions(
            for: coverMonth.month,
            includeCarryover: includeCarryover
        )
    }

    func canBeginSelection(options: [BudgetOverspentCategoryOption]) -> Bool {
        options.count >= 2 && !isBusyCovering
    }

    func canCover(_ option: BudgetOverspentCategoryOption) -> Bool {
        !isBusyCovering
    }

    func beginSelection(options: [BudgetOverspentCategoryOption]) {
        selectionWorkflow.beginSelection(eligibleIDs: options.map(\.id))
    }

    func endSelection() {
        guard !isCovering else {
            return
        }
        selectionWorkflow.endSelection()
    }

    func toggleSelection(_ option: BudgetOverspentCategoryOption) {
        selectionWorkflow.toggleSelection(option.id, isEligible: true)
    }

    func clearErrorMessage() {
        errorMessageValue = nil
    }

    func beginSingleCover(for option: BudgetOverspentCategoryOption) {
        guard canCover(option) else {
            return
        }

        moveMoneyWorkflow.begin(for: option.category)
    }

    func cancelSingleCover() {
        guard !moveMoneyWorkflow.isSubmitting else {
            return
        }
        moveMoneyWorkflow.cancel()
    }

    func coveringCommands(
        options: [BudgetOverspentCategoryOption],
        source: BudgetOverspentCoverSource
    ) -> [BudgetMoveMoneyCommand] {
        selectionWorkflow.coverCommands(options: options, source: source)
    }

    enum CoverResult: Equatable {
        case failed
        case covered(hasRemainingOverspending: Bool)

        var didChange: Bool {
            if case .covered = self {
                return true
            }
            return false
        }

        var resolvedAll: Bool {
            self == .covered(hasRemainingOverspending: false)
        }
    }

    func coverSelection(
        source: BudgetOverspentCoverSource,
        includeCarryover: Bool,
        budgetID: String,
        month: String,
        repository: any BudgetRepositoryProtocol
    ) async -> CoverResult {
        guard !isBusyCovering else {
            return .failed
        }

        let options = options(includeCarryover: includeCarryover)
        let commands = selectionWorkflow.coverCommands(options: options, source: source)
        guard commands.count == selectionWorkflow.selectedCategoryIDs.count else {
            errorMessageValue = "One or more selected categories are no longer overspent."
            return .failed
        }

        selectionWorkflow.markSubmitting()
        errorMessageValue = nil

        do {
            let loadedMonth = try await repository.moveMoneyAndRefresh(
                commands: commands,
                budgetID: budgetID,
                month: month
            ) {}
            selectionWorkflow.finishSubmission(success: true)
            apply(loadedMonth)
            return .covered(hasRemainingOverspending: !self.options(includeCarryover: includeCarryover).isEmpty)
        } catch {
            selectionWorkflow.finishSubmission(success: false)
            errorMessageValue = error.localizedDescription
            return .failed
        }
    }

    func submitSingleCover(
        includeCarryover: Bool,
        budgetID: String,
        month: String,
        repository: any BudgetRepositoryProtocol
    ) async -> CoverResult {
        guard let loadedMonth = await moveMoneyWorkflow.submit(
            selectedMonth: month,
            budgetID: budgetID,
            repository: repository
        ) else {
            return .failed
        }

        apply(loadedMonth)
        return .covered(
            hasRemainingOverspending: !options(includeCarryover: includeCarryover).isEmpty
        )
    }

    private func apply(_ loadedMonth: LoadedBudgetMonth) {
        coverMonth = loadedMonth
        let eligibleIDs = Set(loadedMonth.month.categoryGroups
            .filter { !$0.isIncome }
            .flatMap(\.visibleCategories)
            .filter { $0.balance < 0 }
            .map(\.id))
        selectionWorkflow.intersectSelection(with: eligibleIDs)
    }

    static func overspentOptions(
        for month: BudgetMonth,
        includeCarryover: Bool
    ) -> [BudgetOverspentCategoryOption] {
        month.categoryGroups
            .filter { !$0.isIncome }
            .flatMap { group in
                group.visibleCategories.compactMap { category in
                    guard category.balance < 0,
                          includeCarryover || !category.carryover else {
                        return nil
                    }

                    return BudgetOverspentCategoryOption(
                        id: category.id,
                        groupName: group.name,
                        category: category
                    )
                }
            }
    }
}
