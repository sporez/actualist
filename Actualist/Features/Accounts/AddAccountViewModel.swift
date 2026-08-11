import Foundation
import Observation

@MainActor
@Observable
final class AddAccountViewModel {
    enum AccountKind: String, CaseIterable, Identifiable {
        case budget
        case offBudget

        var id: String { rawValue }

        var title: String {
            switch self {
            case .budget: "Budget"
            case .offBudget: "Off Budget"
            }
        }

        var detail: String {
            switch self {
            case .budget: "Included in the budget."
            case .offBudget: "Tracked outside the budget."
            }
        }

        var offbudget: Bool {
            self == .offBudget
        }
    }

    var name = ""
    var kind: AccountKind = .budget
    var isSubmitting = false
    var errorMessage: String?

    var canSubmit: Bool {
        !trimmedName.isEmpty && !isSubmitting
    }

    func reset() {
        name = ""
        kind = .budget
        isSubmitting = false
        errorMessage = nil
    }

    func submit(
        budgetID: String?,
        repository: (any AccountRepositoryProtocol)?
    ) async -> Bool {
        errorMessage = nil

        guard !isSubmitting else {
            return false
        }

        guard let budgetID else {
            errorMessage = "Choose a budget before adding an account."
            return false
        }

        guard let repository else {
            errorMessage = "Account changes are unavailable right now."
            return false
        }

        let accountName = trimmedName
        guard !accountName.isEmpty else {
            errorMessage = "Enter an account name."
            return false
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await repository.createAccountAndRefresh(
                budgetID: budgetID,
                name: accountName,
                offbudget: kind.offbudget
            )
            reset()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
