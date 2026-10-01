import Foundation
import Observation

@MainActor
@Observable
final class TransactionBatchCategoryPickerWorkflow {
    private(set) var groups: [TransactionEditorCategoryGroup] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var searchText = ""

    private let budgetID: String
    private let repository: any TransactionRepositoryProtocol
    @ObservationIgnored private var generation: UInt64 = 0

    init(budgetID: String, repository: any TransactionRepositoryProtocol) {
        self.budgetID = budgetID
        self.repository = repository
    }

    var visibleGroups: [TransactionEditorCategoryGroup] {
        TransactionEditorCategoryOptions.matching(groups, query: searchText)
    }

    func load() async {
        generation &+= 1
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration { isLoading = false }
        }
        do {
            let options = try await repository.editorOptions(
                budgetID: budgetID,
                month: YearMonth(date: Date()).rawValue
            )
            guard generation == requestGeneration, !Task.isCancelled else { return }
            groups = options.categoryGroups.isEmpty
                ? TransactionEditorCategoryOptions.fallbackGroups(categories: options.categories)
                : options.categoryGroups
        } catch {
            guard generation == requestGeneration, !Task.isCancelled, !error.isCancellation else { return }
            errorMessage = error.userFacingMessage
        }
    }

    func cancel() {
        generation &+= 1
        isLoading = false
    }
}
