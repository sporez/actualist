import Testing
@testable import Actualist

@MainActor
struct OverspentCoverGenerationTests {
    @Test func invalidatedSubmissionCannotFinishANewSelection() {
        let workflow = OverspentCoverSelectionWorkflow()
        workflow.beginSelection(eligibleIDs: ["old"])
        workflow.toggleSelection("old", isEligible: true)
        workflow.markSubmitting()
        let oldGeneration = workflow.currentSubmissionGeneration

        workflow.endSelection()
        workflow.beginSelection(eligibleIDs: ["new"])
        workflow.toggleSelection("new", isEligible: true)
        workflow.markSubmitting()

        #expect(!workflow.finishSubmission(success: true, expectedGeneration: oldGeneration))
        #expect(workflow.selectedCategoryIDs == ["new"])
        #expect(workflow.isSelecting)
        #expect(workflow.isSubmitting)
    }
}
