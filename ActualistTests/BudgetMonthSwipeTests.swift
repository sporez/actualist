import CoreGraphics
import Testing
@testable import Actualist

struct BudgetMonthSwipePolicyTests {
    let policy = BudgetMonthSwipePolicy()
    let viewport = CGSize(width: 400, height: 700)

    func sample(startX: CGFloat, x: CGFloat, y: CGFloat = 0) -> BudgetMonthSwipePolicy.Drag {
        var drag = BudgetMonthSwipePolicy.Drag()
        policy.update(&drag, start: CGPoint(x: startX, y: 200), translation: CGSize(width: x, height: y), viewport: viewport, enabled: true)
        return drag
    }

    @Test func edgeAndCommitBoundaries() {
        #expect(policy.committedDirection(sample(startX: 20, x: 100)) == .previous)
        #expect(policy.committedDirection(sample(startX: 380, x: -100)) == .next)
        #expect(policy.committedDirection(sample(startX: 21, x: 150)) == nil)
        #expect(policy.committedDirection(sample(startX: 379, x: -150)) == nil)
        #expect(policy.committedDirection(sample(startX: 0, x: 99)) == nil)
        #expect(policy.committedDirection(sample(startX: 400, x: -99)) == nil)
        #expect(sample(startX: 0, x: -120).recognition == .rejected)
        #expect(sample(startX: 400, x: 120).recognition == .rejected)
    }

    @Test func rejectedVerticalAndInteriorStartsStayRejected() {
        for initial in [sample(startX: 0, x: 10, y: 20), sample(startX: 200, x: 20), sample(startX: 0, x: 20, y: 20)] {
            var drag = initial
            policy.update(&drag, start: .init(x: 0, y: 200), translation: .init(width: 180, height: 20), viewport: viewport, enabled: true)
            #expect(drag.recognition == initial.recognition)
            #expect(policy.committedDirection(drag) == nil)
            #expect(policy.previewOffset(drag) == 0)
        }
    }

    @Test func verticalRecognitionDoesNotDisableNativeScrolling() {
        let vertical = sample(startX: 0, x: 10, y: 30)
        #expect(vertical.recognition == .vertical)
        #expect(!policy.suppressesControls(vertical))
        #expect(policy.suppressesControls(sample(startX: 200, x: 50)))
    }

    @Test func shortAndReversedDragsDoNotCommit() {
        var drag = sample(startX: 0, x: 110)
        policy.update(&drag, start: .init(x: 0, y: 200), translation: .init(width: 30, height: 0), viewport: viewport, enabled: true)
        #expect(policy.committedDirection(drag) == nil)
        policy.update(&drag, start: .init(x: 0, y: 200), translation: .init(width: -20, height: 0), viewport: viewport, enabled: true)
        #expect(policy.previewOffset(drag) == 0)
        #expect(policy.committedDirection(drag) == nil)
    }

    @Test func interruptedGestureCannotReviveAfterEligibilityReturns() {
        var drag = sample(startX: 0, x: 110)
        policy.update(&drag, start: .init(x: 0, y: 200), translation: .init(width: 180, height: 0),
                      viewport: viewport, enabled: true, revision: 1)
        #expect(policy.committedDirection(drag) == nil)
    }

    @Test func rowsTrackFingerAcrossTheWholeViewport() {
        #expect(policy.previewOffset(sample(startX: 0, x: 80)) == 80)
        #expect(policy.previewOffset(sample(startX: 400, x: -250)) == -250)
        #expect(policy.previewOffset(sample(startX: 0, x: 350)) == 350)
    }

    @Test func resizeAndDisablingRejectTheWholeDrag() {
        for enabled in [true, false] {
            var drag = sample(startX: 0, x: 110)
            policy.update(&drag, start: .init(x: 0, y: 200), translation: .init(width: 180, height: 0),
                          viewport: enabled ? .init(width: 600, height: 700) : viewport, enabled: enabled)
            #expect(policy.committedDirection(drag) == nil)
        }
        #expect(policy.previewOffset(sample(startX: 0, x: 1000)) == viewport.width)
    }
}

@MainActor
struct BudgetMonthSwipeNavigationTests {
    func model(_ month: String = "2026-12") -> BudgetViewModel {
        BudgetViewModel(initialMonth: BudgetViewportFixtures.loaded(month), initialBudgetID: "budget")
    }

    @Test func movesOneCalendarMonthAndPreservesCollapsedGroups() async throws {
        let model = model()
        model.expandedGroupIDs = []
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2027-01"))
        await repository.set(BudgetViewportFixtures.loaded("2026-12"))
        let navigation = BudgetMonthSwipeNavigation()
        await navigation.navigate(.next, model: model, budgetID: "budget", repository: repository)?.value
        #expect(model.selectedMonth == "2027-01")
        #expect(model.budgetMonth?.month == "2027-01")
        #expect(model.expandedGroupIDs.isEmpty)
        await navigation.navigate(.previous, model: model, budgetID: "budget", repository: repository)?.value
        #expect(model.selectedMonth == "2026-12")
        #expect(navigation.requestID == nil)
    }

    @Test func blocksActiveDraftAndDoesNotMutateIt() async throws {
        let model = model()
        model.beginAssignmentEditing(for: try #require(model.visibleGroups.first?.categories.first))
        model.appendAssignmentDigit(7)
        let navigation = BudgetMonthSwipeNavigation()
        #expect(navigation.navigate(.next, model: model, budgetID: "budget", repository: BudgetViewportTestRepository()) == nil)
        #expect(model.selectedMonth == "2026-12")
        #expect(model.assignmentDraft?.inputDigits == "7")
    }

    @Test func draftOpenedBeforeScheduledNavigationIsPreserved() async throws {
        let model = model()
        let navigation = BudgetMonthSwipeNavigation()
        let request = try #require(navigation.navigate(.next, model: model, budgetID: "budget", repository: BudgetViewportTestRepository()))
        model.beginAssignmentEditing(for: try #require(model.visibleGroups.first?.categories.first))
        model.appendAssignmentDigit(3)
        await request.value
        #expect(model.selectedMonth == "2026-12")
        #expect(model.assignmentDraft?.inputDigits == "3")
    }

    @Test func duplicateAndCancelledReadCannotMoveMonth() async throws {
        let model = model()
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2027-01"))
        await repository.block("2027-01")
        let navigation = BudgetMonthSwipeNavigation()
        let first = try #require(navigation.navigate(.next, model: model, budgetID: "budget", repository: repository))
        await repository.waitUntilReadBlocked("2027-01")
        #expect(navigation.navigate(.next, model: model, budgetID: "budget", repository: repository) == nil)
        navigation.cancel()
        await repository.release("2027-01")
        await first.value
        #expect(model.selectedMonth == "2026-12")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test func failureKeepsOldMonthAndNewBudgetSupersedesLateResult() async throws {
        let model = model()
        let repository = BudgetViewportTestRepository()
        let navigation = BudgetMonthSwipeNavigation()
        await navigation.navigate(.next, model: model, budgetID: "budget", repository: repository)?.value
        #expect(model.selectedMonth == "2026-12")
        #expect(model.errorMessage != nil)
        await repository.set(BudgetViewportFixtures.loaded("2027-01"))
        await repository.set(BudgetViewportFixtures.loaded("2026-09"))
        await repository.block("2027-01")
        let first = try #require(navigation.navigate(.next, model: model, budgetID: "budget", repository: repository))
        await repository.waitUntilReadBlocked("2027-01")
        navigation.cancel()
        await model.selectMonth("2026-09", budgetID: "replacement", repository: repository)
        await repository.release("2027-01")
        await first.value
        #expect(model.selectedMonth == "2026-09")
        #expect(model.loadedBudgetID == "replacement")
        #expect(model.errorMessage == nil)
    }

    @Test func refusesDateBoundsAndWrongBudget() {
        let navigation = BudgetMonthSwipeNavigation()
        let repository = BudgetViewportTestRepository()
        #expect(navigation.navigate(.previous, model: model("1900-01"), budgetID: "budget", repository: repository) == nil)
        #expect(navigation.navigate(.next, model: model("9999-12"), budgetID: "budget", repository: repository) == nil)
        #expect(navigation.navigate(.next, model: model(), budgetID: "different", repository: repository) == nil)
    }
}
