import Foundation
import Testing
@testable import Actualist

/// Pins the state machine Merge and Duplicate share, by running every scenario
/// against both coordinators through one probe each.
@MainActor
struct ReviewCommandCoordinatorTests {
    enum Command: String, CaseIterable, CustomTestStringConvertible {
        case merge
        case duplicate

        var testDescription: String { rawValue }

        @MainActor func makeProbe() -> any ReviewCoordinatorProbe {
            switch self {
            case .merge: MergeCoordinatorProbe()
            case .duplicate: DuplicateCoordinatorProbe()
            }
        }
    }

    @Test(arguments: Command.allCases)
    func preparationAcceptSubmitAndCompleteReturnToIdle(command: Command) throws {
        let probe = command.makeProbe()
        #expect(probe.phase == .idle)
        #expect(!probe.isSubmitting && !probe.hidesSelectionChrome && probe.failureMessage == nil)

        let handle = try #require(try probe.begin(["first", "second"]))
        #expect(probe.phase == .preparing)
        #expect(probe.isCurrent(handle))
        #expect(!probe.isSubmitting && probe.hidesSelectionChrome)
        // A second preparation cannot start while one is in flight.
        #expect(try probe.begin(["first", "second"]) == nil)

        #expect(try probe.accept(handle, .valid(id: "review")))
        #expect(probe.phase == .reviewing)
        #expect(!probe.isCurrent(handle))
        #expect(!probe.isSubmitting && probe.hidesSelectionChrome)
        #expect(try probe.begin(["first", "second"]) == nil)

        #expect(probe.beginSubmission() == "review")
        #expect(probe.phase == .submitting)
        #expect(probe.isSubmitting && probe.hidesSelectionChrome)
        #expect(probe.beginSubmission() == nil)
        #expect(try probe.begin(["first", "second"]) == nil)

        #expect(probe.completeSubmission("other") == false)
        #expect(probe.phase == .submitting)
        #expect(probe.completeSubmission("review"))
        #expect(probe.phase == .idle)
        #expect(!probe.isSubmitting && !probe.hidesSelectionChrome)
        #expect(probe.completeSubmission("review") == false)
    }

    @Test(arguments: Command.allCases)
    func emptySelectionDoesNotStartPreparation(command: Command) throws {
        let probe = command.makeProbe()
        #expect(try probe.begin([]) == nil)
        #expect(probe.phase == .idle)
    }

    @Test(arguments: Command.allCases)
    func stalePreparationCannotAcceptOrFail(command: Command) throws {
        let probe = command.makeProbe()
        let stale = try #require(try probe.begin(["first", "second"]))
        probe.cancelPreparation(stale)
        #expect(probe.phase == .idle)
        let current = try #require(try probe.begin(["first", "second"]))

        #expect(!probe.isCurrent(stale))
        #expect(try probe.accept(stale, .valid(id: "stale")) == false)
        probe.failPreparation(stale, "late")
        probe.cancelPreparation(stale)
        #expect(probe.phase == .preparing)
        #expect(probe.isCurrent(current))

        #expect(try probe.accept(current, .valid(id: "current")))
        #expect(probe.reviewID == "current")
    }

    @Test(arguments: Command.allCases)
    func invalidatingDuringPreparationMakesItStale(command: Command) throws {
        let probe = command.makeProbe()
        let handle = try #require(try probe.begin(["first", "second"]))
        probe.invalidate()
        #expect(probe.phase == .idle)
        #expect(!probe.isCurrent(handle))
        #expect(try probe.accept(handle, .valid(id: "late")) == false)
        #expect(probe.phase == .idle)
    }

    @Test(arguments: Command.allCases)
    func rejectedReviewsKeepThePreparationCurrent(command: Command) throws {
        let probe = command.makeProbe()
        let handle = try #require(try probe.begin(["first", "second"]))

        #expect(try probe.accept(handle, .emptyID) == false)
        #expect(try probe.accept(handle, .otherContext(id: "review")) == false)
        #expect(try probe.accept(handle, .swappedOrder(id: "review")) == false)
        #expect(probe.phase == .preparing)
        #expect(probe.isCurrent(handle))

        probe.failPreparation(handle, "This selection changed. Review it again before continuing.")
        #expect(probe.phase == .failed)
        #expect(probe.failureMessage == "This selection changed. Review it again before continuing.")
        #expect(!probe.isSubmitting && !probe.hidesSelectionChrome)
    }

    @Test(arguments: Command.allCases)
    func cancelPreparationAndCancelReviewReturnToIdle(command: Command) throws {
        let probe = command.makeProbe()
        let first = try #require(try probe.begin(["first", "second"]))
        probe.cancelReview()
        #expect(probe.phase == .preparing)
        probe.cancelPreparation(first)
        #expect(probe.phase == .idle)

        let second = try #require(try probe.begin(["first", "second"]))
        #expect(try probe.accept(second, .valid(id: "review")))
        probe.cancelReview()
        #expect(probe.phase == .idle)
        #expect(probe.beginSubmission() == nil)
    }

    @Test(arguments: Command.allCases)
    func failedPreparationAndSubmissionCanBeDismissedOrRestarted(command: Command) throws {
        let probe = command.makeProbe()
        let first = try #require(try probe.begin(["first", "second"]))
        probe.failPreparation(first, "Preparing failed.")
        #expect(probe.failureMessage == "Preparing failed.")
        probe.dismissFailure()
        #expect(probe.phase == .idle)
        #expect(probe.failureMessage == nil)

        let second = try #require(try probe.begin(["first", "second"]))
        probe.failPreparation(second, "Failed again.")
        // A failed state allows the next preparation without a dismissal.
        let third = try #require(try probe.begin(["first", "second"]))
        #expect(probe.phase == .preparing)
        #expect(try probe.accept(third, .valid(id: "review")))
        _ = probe.beginSubmission()
        probe.failSubmission("other", "wrong review")
        #expect(probe.phase == .submitting)
        probe.failSubmission("review", "The save failed.")
        #expect(probe.phase == .failed)
        #expect(probe.failureMessage == "The save failed.")
        #expect(!probe.isSubmitting && !probe.hidesSelectionChrome)
        probe.dismissFailure()
        #expect(probe.phase == .idle)
        probe.dismissFailure()
        #expect(probe.phase == .idle)
    }

    @Test(arguments: Command.allCases)
    func invalidateAndCancelActiveLeaveASubmitAlone(command: Command) throws {
        let probe = command.makeProbe()
        let handle = try #require(try probe.begin(["first", "second"]))
        #expect(try probe.accept(handle, .valid(id: "review")))
        _ = probe.beginSubmission()

        probe.invalidate()
        probe.cancelActive()
        #expect(probe.phase == .submitting)
        #expect(probe.completeSubmission("review"))

        let preparing = try #require(try probe.begin(["first", "second"]))
        probe.cancelActive()
        #expect(probe.phase == .idle)
        #expect(!probe.isCurrent(preparing))

        let reviewed = try #require(try probe.begin(["first", "second"]))
        #expect(try probe.accept(reviewed, .valid(id: "review")))
        probe.cancelActive()
        #expect(probe.phase == .idle)

        let failed = try #require(try probe.begin(["first", "second"]))
        probe.failPreparation(failed, "Failed.")
        probe.cancelActive()
        #expect(probe.phase == .idle)

        let invalidated = try #require(try probe.begin(["first", "second"]))
        #expect(try probe.accept(invalidated, .valid(id: "review")))
        probe.invalidate()
        #expect(probe.phase == .idle)
    }

    // MARK: Per-command rules

    @Test func mergeBlockedReviewIsAcceptedButNeverSubmits() throws {
        let coordinator = TransactionMergeCoordinator()
        let context = makeCommandContext()
        let child = try identity("child", familyRootID: "parent", role: .child)
        let other = try identity("other")
        let preparation = try #require(coordinator.beginPreparation(context: context, selections: [child, other]))
        let blocked = mergeReview(
            context: context, orderedIDs: ["child", "other"],
            blocked: .selectedChild("child"), kept: nil, dropped: nil
        )

        #expect(coordinator.accept(blocked, for: preparation))
        #expect(coordinator.review?.blockedReason == .selectedChild("child"))
        #expect(coordinator.beginSubmission() == nil)
        #expect(!coordinator.isSubmitting)
        #expect(coordinator.hidesSelectionChrome)
    }

    @Test func mergePreparationExposesTheTapOrderedIDs() throws {
        let coordinator = TransactionMergeCoordinator()
        let preparation = try #require(coordinator.beginPreparation(
            context: makeCommandContext(),
            selections: [identity("later"), identity("earlier")]
        ))
        #expect(preparation.orderedTransactionIDs == ["later", "earlier"])
    }

    @Test func duplicateAcceptValidatesSelectionsAndGroups() throws {
        let coordinator = TransactionDuplicateCoordinator()
        let context = makeCommandContext()
        let first = try identity("first")
        let second = try identity("second")
        let selections = [first, second]
        let preparation = try #require(coordinator.beginPreparation(context: context, selections: selections))

        // A group list missing a selection, with a submittable review, is rejected.
        #expect(coordinator.accept(
            duplicateReview(context: context, selections: selections, groupIDs: ["first"]),
            for: preparation
        ) == false)
        // A selection echoed in a different order is rejected.
        #expect(coordinator.accept(
            duplicateReview(context: context, selections: [second, first], groupIDs: ["first", "second"]),
            for: preparation
        ) == false)
        // A selection echo with a different identity set is rejected.
        #expect(coordinator.accept(
            duplicateReview(context: context, selections: [first], groupIDs: ["first"]),
            for: preparation
        ) == false)
        #expect(coordinator.isCurrent(preparation))

        // Every selection accounted for, in one collapsed family group, is accepted.
        #expect(coordinator.accept(
            duplicateReview(context: context, selections: selections, groupIDs: ["first", "second"], singleGroup: true),
            for: preparation
        ))
        #expect(coordinator.beginSubmission()?.selections == selections)
    }
}

// MARK: - Probes

enum ReviewPhase: Equatable {
    case idle, preparing, reviewing, submitting, failed
}

enum ProbeReview {
    case valid(id: String)
    case emptyID
    case otherContext(id: String)
    case swappedOrder(id: String)
}

@MainActor
protocol ReviewCoordinatorProbe: AnyObject {
    var phase: ReviewPhase { get }
    var isSubmitting: Bool { get }
    var hidesSelectionChrome: Bool { get }
    var failureMessage: String? { get }
    var reviewID: String? { get }

    func begin(_ ids: [String]) throws -> Int?
    func isCurrent(_ handle: Int) -> Bool
    func accept(_ handle: Int, _ review: ProbeReview) throws -> Bool
    func failPreparation(_ handle: Int, _ message: String)
    func cancelPreparation(_ handle: Int)
    func cancelReview()
    func dismissFailure()
    func beginSubmission() -> String?
    func completeSubmission(_ reviewID: String) -> Bool
    func failSubmission(_ reviewID: String, _ message: String)
    func invalidate()
    func cancelActive()
}

private func otherContext() -> TransactionSelectionContext {
    TransactionSelectionContext(
        budgetID: "other-budget",
        sessionGeneration: 1,
        scope: .spending,
        querySignature: TransactionFeedQuery().signature
    )
}

@MainActor
private final class MergeCoordinatorProbe: ReviewCoordinatorProbe {
    let coordinator = TransactionMergeCoordinator()
    let context = makeCommandContext()
    private var preparations: [Int: TransactionMergeCoordinator.Preparation] = [:]

    var phase: ReviewPhase {
        switch coordinator.state {
        case .idle: .idle
        case .preparing: .preparing
        case .reviewing: .reviewing
        case .submitting: .submitting
        case .failed: .failed
        }
    }
    var isSubmitting: Bool { coordinator.isSubmitting }
    var hidesSelectionChrome: Bool { coordinator.hidesSelectionChrome }
    var failureMessage: String? { coordinator.failureMessage }
    var reviewID: String? { coordinator.review?.id }

    func begin(_ ids: [String]) throws -> Int? {
        let selections = try ids.map { try identity($0) }
        guard let preparation = coordinator.beginPreparation(context: context, selections: selections) else {
            return nil
        }
        let handle = preparations.count
        preparations[handle] = preparation
        return handle
    }

    func isCurrent(_ handle: Int) -> Bool { coordinator.isCurrent(preparations[handle]!) }

    func accept(_ handle: Int, _ review: ProbeReview) throws -> Bool {
        let preparation = preparations[handle]!
        let ids = preparation.orderedTransactionIDs
        let built: TransactionMergeReview
        switch review {
        case .valid(let id): built = mergeReview(context: context, orderedIDs: ids, id: id)
        case .emptyID: built = mergeReview(context: context, orderedIDs: ids, id: "")
        case .otherContext(let id): built = mergeReview(context: otherContext(), orderedIDs: ids, id: id)
        case .swappedOrder(let id): built = mergeReview(context: context, orderedIDs: ids.reversed(), id: id)
        }
        return coordinator.accept(built, for: preparation)
    }

    func failPreparation(_ handle: Int, _ message: String) {
        coordinator.failPreparation(preparations[handle]!, message: message)
    }
    func cancelPreparation(_ handle: Int) { coordinator.cancelPreparation(preparations[handle]!) }
    func cancelReview() { coordinator.cancelReview() }
    func dismissFailure() { coordinator.dismissFailure() }
    func beginSubmission() -> String? { coordinator.beginSubmission()?.id }
    func completeSubmission(_ reviewID: String) -> Bool { coordinator.completeSubmission(reviewID: reviewID) }
    func failSubmission(_ reviewID: String, _ message: String) {
        coordinator.failSubmission(reviewID: reviewID, message: message)
    }
    func invalidate() { coordinator.invalidate() }
    func cancelActive() { coordinator.cancelActive() }
}

@MainActor
private final class DuplicateCoordinatorProbe: ReviewCoordinatorProbe {
    let coordinator = TransactionDuplicateCoordinator()
    let context = makeCommandContext()
    private var preparations: [Int: TransactionDuplicateCoordinator.Preparation] = [:]

    var phase: ReviewPhase {
        switch coordinator.state {
        case .idle: .idle
        case .preparing: .preparing
        case .reviewing: .reviewing
        case .submitting: .submitting
        case .failed: .failed
        }
    }
    var isSubmitting: Bool { coordinator.isSubmitting }
    var hidesSelectionChrome: Bool { coordinator.hidesSelectionChrome }
    var failureMessage: String? { coordinator.failureMessage }
    var reviewID: String? {
        switch coordinator.state {
        case .reviewing(let review), .submitting(let review): review.id
        case .idle, .preparing, .failed: nil
        }
    }

    func begin(_ ids: [String]) throws -> Int? {
        let selections = try ids.map { try identity($0) }
        guard let preparation = coordinator.beginPreparation(context: context, selections: selections) else {
            return nil
        }
        let handle = preparations.count
        preparations[handle] = preparation
        return handle
    }

    func isCurrent(_ handle: Int) -> Bool { coordinator.isCurrent(preparations[handle]!) }

    func accept(_ handle: Int, _ review: ProbeReview) throws -> Bool {
        let preparation = preparations[handle]!
        let selections = preparation.selections
        let ids = selections.map(\.transactionID)
        let built: TransactionDuplicateReview
        switch review {
        case .valid(let id):
            built = duplicateReview(context: context, selections: selections, groupIDs: ids, id: id)
        case .emptyID:
            built = duplicateReview(context: context, selections: selections, groupIDs: ids, id: "")
        case .otherContext(let id):
            built = duplicateReview(context: otherContext(), selections: selections, groupIDs: ids, id: id)
        case .swappedOrder(let id):
            built = duplicateReview(context: context, selections: selections.reversed(), groupIDs: ids, id: id)
        }
        return coordinator.accept(built, for: preparation)
    }

    func failPreparation(_ handle: Int, _ message: String) {
        coordinator.failPreparation(preparations[handle]!, message: message)
    }
    func cancelPreparation(_ handle: Int) { coordinator.cancelPreparation(preparations[handle]!) }
    func cancelReview() { coordinator.cancelReview() }
    func dismissFailure() { coordinator.dismissFailure() }
    func beginSubmission() -> String? { coordinator.beginSubmission()?.id }
    func completeSubmission(_ reviewID: String) -> Bool { coordinator.completeSubmission(reviewID: reviewID) }
    func failSubmission(_ reviewID: String, _ message: String) {
        coordinator.failSubmission(reviewID: reviewID, message: message)
    }
    func invalidate() { coordinator.invalidate() }
    func cancelActive() { coordinator.cancelActive() }
}
