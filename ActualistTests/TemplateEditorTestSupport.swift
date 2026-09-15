import Foundation
import Testing
@testable import Actualist

/// Poll preview off the main actor. An Observation wait can miss the
/// loading → ready flip, and a MainActor sleep can starve the dry-run that
/// would clear `.loading`, so a full suite then hits the 2-minute test limit.
func waitForTemplatePreview(
    _ viewModel: BudgetTemplateEditorViewModel,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while await viewModel.previewState == .loading {
        try Task.checkCancellation()
        try #require(
            ContinuousClock.now < deadline,
            "template preview stayed loading",
            sourceLocation: sourceLocation
        )
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(await viewModel.dryRun != nil, sourceLocation: sourceLocation)
}
