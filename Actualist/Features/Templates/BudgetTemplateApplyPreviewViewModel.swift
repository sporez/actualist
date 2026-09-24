import Foundation
import Observation

@MainActor
@Observable
final class BudgetTemplateApplyPreviewViewModel {
    enum Mode: String, CaseIterable, Equatable, Identifiable, Sendable {
        case fillEmpty
        case overwrite

        var id: String { rawValue }

        var confirmation: BudgetTemplateConfirmation {
            switch self {
            case .fillEmpty: .monthFillEmpty
            case .overwrite: .monthOverwrite
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed
    }

    private indirect enum State {
        case idle
        case loading
        case refreshing(State)
        case categoryReady(BudgetTemplateApplyPreview, randomized: Bool)
        case paired(BudgetTemplateApplyPreviewPair, randomized: Bool)
        case failed(String)
    }

    private(set) var selectedMode: Mode?

    private var state: State = .loading
    private var loadGeneration = 0
    private var requestContext: RequestContext?
    private var completedRequest: PreviewRequest?

    var phase: Phase {
        switch state {
        case .idle: return .idle
        case .loading, .refreshing: return .loading
        case .categoryReady: return .ready
        case .failed: return .failed
        case .paired(let pair, _):
            if case .ready = selectedOutcome(in: pair) {
                return .ready
            }
            return .failed
        }
    }

    var display: BudgetTemplateApplyPreviewDisplay? {
        display(in: state)
    }

    private func display(in state: State) -> BudgetTemplateApplyPreviewDisplay? {
        switch state {
        case .refreshing(let previous):
            return display(in: previous)
        case .categoryReady(let preview, let randomized):
            return BudgetTemplateApplyPreviewDisplay.make(
                preview: preview, randomized: randomized
            )
        case .paired(let pair, let randomized):
            guard case .ready(let preview) = selectedOutcome(in: pair) else { return nil }
            return BudgetTemplateApplyPreviewDisplay.make(
                preview: preview, randomized: randomized
            )
        case .idle, .loading, .failed:
            return nil
        }
    }

    var errorMessage: String? {
        switch state {
        case .failed(let message):
            return message
        case .paired(let pair, let randomized):
            guard case .failed(let message) = selectedOutcome(in: pair) else { return nil }
            return randomized ? "Template preview unavailable for this option." : message
        case .idle, .loading, .refreshing, .categoryReady:
            return nil
        }
    }

    var selectedConfirmation: BudgetTemplateConfirmation? {
        selectedMode?.confirmation
    }

    var reviewRevision: BudgetTemplateReviewRevision? {
        switch state {
        case .categoryReady(let preview, _):
            preview.reviewRevision
        case .paired(let pair, _):
            selectedPreview(in: pair)?.reviewRevision
        case .idle, .loading, .refreshing, .failed:
            nil
        }
    }

    var canApply: Bool {
        phase == .ready && errorMessage == nil && reviewRevision != nil
    }

    func cancel() {
        loadGeneration += 1
        state = .idle
        selectedMode = nil
        requestContext = nil
        completedRequest = nil
    }

    func selectMode(_ mode: Mode) {
        guard selectedMode != nil else { return }
        selectedMode = mode
    }

    func loadIfNeeded(
        revision: UInt64,
        confirmation: BudgetTemplateConfirmation,
        categoryID: String?,
        month: String,
        budgetID: String?,
        modeIdentity: BudgetModeIdentity? = nil,
        randomized: Bool,
        repository: any BudgetRepositoryProtocol
    ) async {
        let request = PreviewRequest(
            context: RequestContext(
                confirmation: confirmation,
                categoryID: categoryID,
                month: month,
                budgetID: budgetID,
                modeIdentity: modeIdentity,
                randomized: randomized
            ),
            revision: revision
        )
        guard completedRequest != request else { return }
        let expectedGeneration = loadGeneration + 1
        await load(
            confirmation: confirmation,
            categoryID: categoryID,
            month: month,
            budgetID: budgetID,
            modeIdentity: modeIdentity,
            randomized: randomized,
            repository: repository
        )
        if !Task.isCancelled, loadGeneration == expectedGeneration,
           requestContext == request.context, phase != .idle {
            completedRequest = request
        }
    }

    func load(
        confirmation: BudgetTemplateConfirmation,
        categoryID: String?,
        month: String,
        budgetID: String?,
        modeIdentity: BudgetModeIdentity? = nil,
        randomized: Bool,
        repository: any BudgetRepositoryProtocol
    ) async {
        loadGeneration += 1
        let requestGeneration = loadGeneration
        let context = RequestContext(
            confirmation: confirmation,
            categoryID: categoryID,
            month: month,
            budgetID: budgetID,
            modeIdentity: modeIdentity,
            randomized: randomized
        )
        let sameContext = requestContext == context
        let shouldResetSelection = !sameContext || selectedMode == nil
        requestContext = context
        if shouldResetSelection {
            selectedMode = mode(for: confirmation)
        }
        if sameContext {
            switch state {
            case .categoryReady, .paired:
                state = .refreshing(state)
            case .refreshing(let previous):
                state = .refreshing(previous)
            case .idle, .loading, .failed:
                state = .loading
            }
        } else {
            state = .loading
        }

        guard let budgetID, !budgetID.isEmpty else {
            fail("No budget is selected.", generation: requestGeneration)
            return
        }
        let trimmedMonth = month.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMonth.isEmpty else {
            fail("No month is selected.", generation: requestGeneration)
            return
        }

        do {
            if confirmation == .category {
                guard let categoryID, let command = confirmation.command(categoryID: categoryID) else {
                    fail("No category is selected.", generation: requestGeneration)
                    return
                }
                let preview = try await repository.previewBudgetTemplate(
                    command: command,
                    budgetID: budgetID,
                    month: trimmedMonth
                )
                guard requestGeneration == loadGeneration, !Task.isCancelled else { return }
                guard preview.modeIdentity == modeIdentity,
                      preview.reviewRevision?.month == trimmedMonth,
                      (modeIdentity == nil || preview.reviewRevision?.modeIdentity == modeIdentity) else {
                    fail(BudgetModeWriteError.budgetChanged.localizedDescription, generation: requestGeneration)
                    return
                }
                state = .categoryReady(preview, randomized: randomized)
            } else {
                let pair = try await repository.previewBudgetTemplatePair(
                    budgetID: budgetID,
                    month: trimmedMonth
                )
                guard requestGeneration == loadGeneration, !Task.isCancelled else { return }
                state = .paired(
                    validated(pair, expectedMode: modeIdentity, month: trimmedMonth),
                    randomized: randomized
                )
            }
        } catch {
            guard requestGeneration == loadGeneration, !Task.isCancelled else { return }
            if let message = error.userFacingMessage {
                fail(randomized ? "Template preview unavailable." : message, generation: requestGeneration)
            } else {
                state = .idle
            }
        }
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == loadGeneration else { return }
        state = .failed(message)
    }

    private func selectedOutcome(in pair: BudgetTemplateApplyPreviewPair) -> BudgetTemplatePreviewOutcome {
        guard let selectedMode else {
            return .failed("No template mode is selected.")
        }
        return selectedMode == .fillEmpty ? pair.fillEmpty : pair.overwrite
    }

    private func selectedPreview(in pair: BudgetTemplateApplyPreviewPair) -> BudgetTemplateApplyPreview? {
        guard case .ready(let preview) = selectedOutcome(in: pair) else { return nil }
        return preview
    }

    private func mode(for confirmation: BudgetTemplateConfirmation) -> Mode? {
        switch confirmation {
        case .monthFillEmpty: .fillEmpty
        case .monthOverwrite: .overwrite
        case .category: nil
        }
    }

    private func validated(
        _ pair: BudgetTemplateApplyPreviewPair,
        expectedMode: BudgetModeIdentity?,
        month: String
    ) -> BudgetTemplateApplyPreviewPair {
        BudgetTemplateApplyPreviewPair(
            fillEmpty: validated(pair.fillEmpty, expectedMode: expectedMode, month: month),
            overwrite: validated(pair.overwrite, expectedMode: expectedMode, month: month)
        )
    }

    private func validated(
        _ outcome: BudgetTemplatePreviewOutcome,
        expectedMode: BudgetModeIdentity?,
        month: String
    ) -> BudgetTemplatePreviewOutcome {
        guard case .ready(let preview) = outcome else { return outcome }
        guard preview.modeIdentity == expectedMode,
              preview.reviewRevision?.month == month,
              (expectedMode == nil || preview.reviewRevision?.modeIdentity == expectedMode) else {
            return .failed(BudgetModeWriteError.budgetChanged.localizedDescription)
        }
        return .ready(preview)
    }

    private struct RequestContext: Equatable {
        let confirmation: BudgetTemplateConfirmation
        let categoryID: String?
        let month: String
        let budgetID: String?
        let modeIdentity: BudgetModeIdentity?
        let randomized: Bool
    }

    private struct PreviewRequest: Equatable {
        let context: RequestContext
        let revision: UInt64
    }
}
