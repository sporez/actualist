import Foundation
import Observation
import Testing
@testable import Actualist

/// Preview deadlines measure shared executor contention, not editor correctness.
/// Observe the real completion; the suite time limit still bounds a stuck test.
@MainActor
func waitForTemplatePreview(
    _ viewModel: BudgetTemplateEditorViewModel,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    while viewModel.previewState == .loading {
        let changes = AsyncStream<Void> { continuation in
            let isLoading = withObservationTracking {
                viewModel.previewState == .loading
            } onChange: {
                continuation.yield(())
                continuation.finish()
            }
            if !isLoading {
                continuation.finish()
            }
        }
        for await _ in changes { break }
        try Task.checkCancellation()
    }
    try #require(viewModel.dryRun != nil, sourceLocation: sourceLocation)
}
