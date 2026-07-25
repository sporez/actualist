import Observation

@MainActor
@Observable
final class BudgetTemplateWorkflow {
    private(set) var submissionState: BudgetAssignmentSubmissionState = .draft

    var isApplying: Bool {
        submissionState.isSubmitting
    }

    func apply(
        command: BudgetTemplateCommand,
        selectedMonth: String,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Result<LoadedBudgetMonth, Error> {
        guard !submissionState.isSubmitting else {
            return .failure(BudgetTemplateWorkflowError.alreadyApplying)
        }

        submissionState = .submitting

        do {
            let loadedMonth = try await repository.applyBudgetTemplateAndRefresh(
                command: command,
                budgetID: budgetID,
                month: selectedMonth
            ) { [weak self] in
                await MainActor.run {
                    self?.submissionState = .refetching
                }
            }
            submissionState = .draft
            return .success(loadedMonth)
        } catch {
            submissionState = .failed(error.localizedDescription)
            return .failure(error)
        }
    }
}

private enum BudgetTemplateWorkflowError: Error {
    case alreadyApplying
}
