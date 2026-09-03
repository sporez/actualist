import Foundation

/// Owns debounced preview identity and cancellation for the template editor.
/// The editor view model remains responsible for deciding whether drafts are
/// previewable and for applying the result to screen state.
@MainActor
final class BudgetTemplateEditorPreviewCoordinator {
    typealias Loader = @MainActor ([BudgetTemplateDraft]) async throws -> BudgetTemplateCategoryDryRun?
    typealias Completion = @MainActor (Result<BudgetTemplateCategoryDryRun?, Error>) -> Void

    private var generation = 0
    private var task: Task<Void, Never>?

    func schedule(
        drafts: [BudgetTemplateDraft],
        delay: Duration,
        load: @escaping Loader,
        completion: @escaping Completion
    ) {
        generation += 1
        let requestGeneration = generation
        task?.cancel()
        task = Task { [weak self] in
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.generation == requestGeneration else {
                return
            }
            do {
                let preview = try await load(drafts)
                guard !Task.isCancelled, self.generation == requestGeneration else {
                    return
                }
                completion(.success(preview))
            } catch {
                guard !Task.isCancelled, self.generation == requestGeneration else {
                    return
                }
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
