import Foundation
import Observation

@MainActor
@Observable
final class BudgetTemplateApplyPreviewViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var display: BudgetTemplateApplyPreviewDisplay?
    var errorMessage: String?

    private var loadGeneration = 0

    var canApply: Bool {
        phase == .ready && errorMessage == nil
    }

    func cancel() {
        loadGeneration += 1
    }

    func load(
        confirmation: BudgetTemplateConfirmation,
        categoryID: String?,
        month: String,
        budgetID: String?,
        randomized: Bool,
        repository: any BudgetRepositoryProtocol
    ) async {
        loadGeneration += 1
        let requestGeneration = loadGeneration
        display = nil
        errorMessage = nil
        phase = .loading

        guard let budgetID, !budgetID.isEmpty else {
            fail("No budget is selected.", generation: requestGeneration)
            return
        }
        let trimmedMonth = month.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMonth.isEmpty else {
            fail("No month is selected.", generation: requestGeneration)
            return
        }
        guard let command = confirmation.command(categoryID: categoryID) else {
            fail("No category is selected.", generation: requestGeneration)
            return
        }

        do {
            let preview = try await repository.previewBudgetTemplate(
                command: command,
                budgetID: budgetID,
                month: trimmedMonth
            )
            guard requestGeneration == loadGeneration else {
                return
            }
            display = BudgetTemplateApplyPreviewDisplay.make(
                preview: preview,
                randomized: randomized,
                month: trimmedMonth
            )
            phase = .ready
        } catch {
            fail(error.localizedDescription, generation: requestGeneration)
        }
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == loadGeneration else {
            return
        }
        errorMessage = message
        display = nil
        phase = .failed
    }
}
