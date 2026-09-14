import SwiftUI
import Testing
@testable import Actualist

@MainActor
struct BudgetAssignmentScrollPresentationTests {
    private func make() -> BudgetAssignmentScrollPresentation {
        let model = BudgetAssignmentScrollPresentation()
        model.viewportBottom = 800
        model.measureFloatingHeight(60)
        model.update(.init(position: 100, maximum: 300, contentHeight: 1000, visibleOffset: 0))
        return model
    }

    private func prepare(_ model: BudgetAssignmentScrollPresentation, bottom: CGFloat = 700) throws -> BudgetAssignmentScrollPresentation.Request {
        model.select(categoryID: "one", rowFrame: CGRect(x: 0, y: bottom - 48, width: 100, height: 48))
        model.measureKeypadHeight(370)
        model.update(.init(position: 100, maximum: 610, contentHeight: 1310, visibleOffset: 0))
        return try #require(model.readyRequest)
    }

    @Test func rangeUsesOnlyAdditionalOcclusion() throws {
        let model = make()
        #expect(model.bottomPadding == 14)
        _ = try prepare(model)
        #expect(model.bottomPadding == 324)
        #expect(BudgetKeypadLayout.initialHeight == 370)
        #expect(BudgetLayout.assignmentScrollVisibilityMargin == 8)
    }

    @Test func visibleRowRetainsPositionWithoutRestoration() throws {
        let model = make()
        let request = try prepare(model, bottom: 300)
        #expect(request.target == 100)
        #expect(request.restoration == nil)
        #expect(model.begin(request))
        #expect(model.readyRequest == nil)
    }

    @Test func occludedRowMovesByOnlyExactOverlap() throws {
        let model = make()
        let request = try prepare(model)
        #expect(request.target == 378)
        #expect(request.restoration == 100)
        #expect(model.begin(request))
        #expect(model.position.y == 378)
    }

    @Test func preparationWaitsForRealRangeAndPinsOrigin() {
        let model = make()
        model.select(categoryID: "one", rowFrame: CGRect(x: 0, y: 652, width: 100, height: 48))
        #expect(model.readyRequest == nil)
        #expect(model.position.y == 100)
        model.update(.init(position: 100, maximum: 300, contentHeight: 1000))
        #expect(model.readyRequest == nil)
    }

    @Test func missingViewportDoesNotInventAnOcclusion() throws {
        let model = make()
        model.viewportBottom = 0
        let request = try prepare(model)
        #expect(request.target == 100)
        #expect(request.restoration == nil)
    }

    @Test func topRubberBandDoesNotProduceNegativePosition() throws {
        let model = make()
        model.update(.init(position: -20, maximum: 300, contentHeight: 1000))
        model.select(categoryID: "one", rowFrame: CGRect(x: 0, y: 252, width: 100, height: 48))
        model.measureKeypadHeight(370)
        #expect(model.position.y == 0)
        model.update(.init(position: 0, maximum: 610, contentHeight: 1310))
        #expect(try #require(model.readyRequest).target == 0)
    }

    @Test func supersededAndCancelledRequestsCannotOpen() throws {
        let model = make()
        let old = try prepare(model)
        model.select(categoryID: "two", rowFrame: CGRect(x: 0, y: 600, width: 100, height: 48))
        #expect(!model.begin(old))
        let latest = try #require(model.readyRequest)
        model.cancelPendingPresentation()
        #expect(!model.begin(latest))
        #expect(model.bottomPadding == 14)
    }

    @Test func secondTapDuringPreparationStillWaitsForClearance() throws {
        let model = make()
        let frame = CGRect(x: 0, y: 652, width: 100, height: 48)
        model.select(categoryID: "one", rowFrame: frame)
        model.select(categoryID: "two", rowFrame: frame)
        model.measureKeypadHeight(370)
        #expect(model.readyRequest == nil)
        model.update(.init(position: 100, maximum: 610, contentHeight: 1310))
        #expect(try #require(model.readyRequest).categoryID == "two")
    }

    @Test func changingRowKeepsOriginalRestoration() throws {
        let model = make()
        let first = try prepare(model)
        model.begin(first)
        model.update(.init(position: 378, maximum: 610, contentHeight: 1310))
        model.select(categoryID: "two", rowFrame: CGRect(x: 0, y: 400, width: 100, height: 48))
        model.measureKeypadHeight(370)
        let second = try #require(model.readyRequest)
        #expect(second.target == 404)
        #expect(second.restoration == 100)
    }

    @Test func dismissalRestoresLiftAndRetiresRangeWithoutSecondScroll() throws {
        let model = make()
        let request = try prepare(model)
        model.begin(request)
        model.update(.init(position: 378, maximum: 610, contentHeight: 1310))
        model.beginClosing(request)
        #expect(model.position.y == 100)
        model.finishClosing(request)
        #expect(model.bottomPadding == 14)
        #expect(model.position.y == 100)
    }

    @Test func visibleRowManualBottomScrollClosesWithinRealRange() throws {
        let model = make()
        let request = try prepare(model, bottom: 300)
        model.begin(request)
        model.update(.init(position: 610, maximum: 610, contentHeight: 1310))
        model.beginClosing(request)
        #expect(model.position.y == 300)
    }

    @Test func staleDismissalCannotRemoveReopenedClearance() throws {
        let model = make()
        let old = try prepare(model)
        model.begin(old)
        model.beginClosing(old)
        model.select(categoryID: "two", rowFrame: CGRect(x: 0, y: 400, width: 100, height: 48))
        let new = try #require(model.readyRequest)
        model.begin(new)
        model.finishClosing(old)
        #expect(model.phase == .editing(new))
        #expect(model.bottomPadding == 324)
    }

    @Test func tallerKeypadRevealsRowWithoutRestartingDraft() throws {
        let model = make()
        let initial = try prepare(model)
        model.begin(initial)
        model.update(.init(position: 378, maximum: 610, contentHeight: 1310))
        model.measureKeypadHeight(420)
        #expect(model.readyRequest == nil)
        #expect(model.bottomPadding == 374)
        model.update(.init(position: 378, maximum: 660, contentHeight: 1360))
        let resized = try #require(model.readyRequest)
        #expect(!resized.startsEditing)
        #expect(resized.target == 428)
        #expect(resized.restoration == 100)
    }
}
