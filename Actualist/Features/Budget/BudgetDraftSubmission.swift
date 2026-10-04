import Foundation

/// The submit protocol shared by the budget draft workflows (assignment,
/// category template, Move Money): mark the draft as refetching once the write
/// commits, drop a result for a superseded context, and invalidate when the
/// budget mode changed. The caller applies the returned outcome to its own draft.
@MainActor
enum BudgetDraftSubmission {
    enum Outcome {
        /// The workflow context changed while the write ran; leave the draft alone.
        case superseded
        /// The budget changed under the draft; the caller invalidates its workflow.
        case invalidated
        case loaded(LoadedBudgetMonth)
        case failed(BudgetAssignmentSubmissionState)
    }

    static func run<Context: Equatable>(
        context: Context,
        modeIdentity: BudgetModeIdentity?,
        currentContext: () -> Context?,
        onCommitted: () -> Void = {},
        markRefetching: @escaping @MainActor @Sendable () -> Void,
        write: (@escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth
    ) async -> Outcome {
        do {
            let loadedMonth = try await write {
                await MainActor.run { markRefetching() }
            }
            onCommitted()
            guard currentContext() == context else { return .superseded }
            guard loadedMonth.modeIdentity == modeIdentity else { return .invalidated }
            return .loaded(loadedMonth)
        } catch {
            guard currentContext() == context else { return .superseded }
            if case BudgetModeWriteError.budgetChanged = error {
                return .invalidated
            }
            return .failed(error.userFacingMessage.map(BudgetAssignmentSubmissionState.failed) ?? .draft)
        }
    }
}
