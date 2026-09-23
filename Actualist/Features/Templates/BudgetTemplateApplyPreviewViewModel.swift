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

    private enum State {
        case idle
        case loading
        case categoryReady(BudgetTemplateApplyPreviewDisplay, BudgetTemplateReviewRevision?)
        case paired(BudgetTemplateApplyPreviewPair, randomized: Bool)
        case failed(String)
    }

    private(set) var selectedMode: Mode?

    private var state: State = .loading
    private var loadGeneration = 0
    private var requestContext: RequestContext?

    var phase: Phase {
        switch state {
        case .idle: return .idle
        case .loading: return .loading
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
        switch state {
        case .categoryReady(let display, _):
            return display
        case .paired(let pair, let randomized):
            guard case .ready(let preview) = selectedOutcome(in: pair) else { return nil }
            return BudgetTemplateApplyPreviewDisplay.make(preview: preview, randomized: randomized)
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
        case .idle, .loading, .categoryReady:
            return nil
        }
    }

    var selectedConfirmation: BudgetTemplateConfirmation? {
        selectedMode?.confirmation
    }

    var reviewRevision: BudgetTemplateReviewRevision? {
        switch state {
        case .categoryReady(_, let revision):
            revision
        case .paired(let pair, _):
            selectedPreview(in: pair)?.reviewRevision
        case .idle, .loading, .failed:
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
    }

    func selectMode(_ mode: Mode) {
        guard selectedMode != nil else { return }
        selectedMode = mode
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
            modeIdentity: modeIdentity
        )
        let shouldResetSelection = requestContext != context || selectedMode == nil
        requestContext = context
        if shouldResetSelection {
            selectedMode = mode(for: confirmation)
        }
        state = .loading

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
                guard requestGeneration == loadGeneration else { return }
                guard preview.modeIdentity == modeIdentity,
                      preview.reviewRevision?.month == trimmedMonth,
                      (modeIdentity == nil || preview.reviewRevision?.modeIdentity == modeIdentity) else {
                    fail(BudgetModeWriteError.budgetChanged.localizedDescription, generation: requestGeneration)
                    return
                }
                state = .categoryReady(
                    BudgetTemplateApplyPreviewDisplay.make(preview: preview, randomized: randomized),
                    preview.reviewRevision
                )
            } else {
                let pair = try await repository.previewBudgetTemplatePair(
                    budgetID: budgetID,
                    month: trimmedMonth
                )
                guard requestGeneration == loadGeneration else { return }
                state = .paired(
                    validated(pair, expectedMode: modeIdentity, month: trimmedMonth),
                    randomized: randomized
                )
            }
        } catch {
            guard requestGeneration == loadGeneration else { return }
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
    }
}
