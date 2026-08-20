import Foundation
import Observation

struct TransactionRulePreviewRequest: Equatable, Sendable {
    let budgetID: String
    let draft: TransactionDraft
    let categorySelection: TransactionEditorCategoryState.Selection
}

enum TransactionRulePreviewOutcome: Equatable, Sendable {
    case applied(TransactionRulePreview)
    case stale
    case unsupported
    case failed(String)
}

@MainActor
@Observable
final class TransactionRulePreviewCoordinator {
    private(set) var isRunning = false
    private var generation = 0

    func preview(
        request: TransactionRulePreviewRequest,
        repository: any TransactionRepositoryProtocol,
        currentRequest: @escaping @MainActor @Sendable () -> TransactionRulePreviewRequest?
    ) async -> TransactionRulePreviewOutcome {
        generation += 1
        let requestGeneration = generation
        isRunning = true
        defer {
            if generation == requestGeneration {
                isRunning = false
            }
        }

        do {
            let preview = try await repository.previewRules(
                for: request.draft,
                budgetID: request.budgetID
            )
            guard !Task.isCancelled,
                  generation == requestGeneration,
                  currentRequest() == request else {
                return .stale
            }
            return .applied(preview)
        } catch {
            guard !Task.isCancelled,
                  generation == requestGeneration,
                  currentRequest() == request else {
                return .stale
            }
            if let localFirstError = error as? LocalFirstError,
               localFirstError == .unsupportedWrite {
                return .unsupported
            }
            return .failed("Could not apply payee rules: \(error.localizedDescription)")
        }
    }

    func cancel() {
        generation += 1
        isRunning = false
    }
}
