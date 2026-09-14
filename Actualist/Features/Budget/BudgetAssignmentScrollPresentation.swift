import SwiftUI
import Observation

/// Owns only compact scroll/keypad presentation. Drafts and writes stay in the assignment workflow.
@MainActor @Observable
final class BudgetAssignmentScrollPresentation {
    struct Sample: Equatable {
        var position: CGFloat = 0
        var maximum: CGFloat = 0
        var contentHeight: CGFloat = 0
        var visibleOffset: CGFloat = 0
    }

    struct Request: Equatable {
        let id = UUID()
        let categoryID: String
        let startsEditing: Bool
        let target: CGFloat
        let restoration: CGFloat?
        let rowBottom: CGFloat
        let requiredContentHeight: CGFloat
    }

    enum Phase: Equatable {
        case idle, preparing(Request), ready(Request), editing(Request), closing(Request)

        var request: Request? {
            switch self {
            case .idle: nil
            case .preparing(let r), .ready(let r), .editing(let r), .closing(let r): r
            }
        }
    }

    var position = ScrollPosition(y: 0)
    private(set) var phase = Phase.idle
    private(set) var floatingHeight: CGFloat = 0
    private(set) var keypadHeight = BudgetKeypadLayout.initialHeight
    private(set) var expansion = ScrollDirectedExpansion()
    private(set) var sample = Sample()
    @ObservationIgnored var viewportBottom: CGFloat = 0

    var clearance: CGFloat { max(0, keypadHeight - floatingHeight) }
    var bottomPadding: CGFloat { BudgetLayout.sectionSpacing + (phase == .idle ? 0 : clearance) }
    var readyRequest: Request? {
        if case .ready(let request) = phase { request } else { nil }
    }

    func measureFloatingHeight(_ height: CGFloat) {
        if abs(floatingHeight - height) > 0.5 { floatingHeight = height }
    }

    func update(_ next: Sample) {
        let previous = sample
        sample = next
        var updated = expansion
        updated.update(previousOffset: previous.visibleOffset, offset: next.visibleOffset, maxOffset: next.maximum)
        if updated != expansion {
            withAnimation(BudgetLayout.addTransactionExpansionAnimation) { expansion = updated }
        }
        if case .preparing(let request) = phase,
           next.contentHeight >= request.requiredContentHeight - 0.5 {
            phase = .ready(request)
        }
    }

    func select(categoryID: String, rowFrame: CGRect) {
        let movement = viewportBottom > 0
            ? max(0, rowFrame.maxY - (viewportBottom - keypadHeight - BudgetLayout.assignmentScrollVisibilityMargin)) : 0
        let origin = max(0, sample.position)
        let previous = phase.request
        let requiredContentHeight: CGFloat
        if case .preparing(let pending) = phase {
            requiredContentHeight = pending.requiredContentHeight
        } else {
            requiredContentHeight = sample.contentHeight + (phase == .idle ? clearance : 0)
        }
        let request = Request(
            categoryID: categoryID, startsEditing: true,
            target: origin + movement,
            restoration: previous?.restoration ?? (movement > 0.5 ? origin : nil),
            rowBottom: rowFrame.maxY + origin,
            requiredContentHeight: requiredContentHeight
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if phase == .idle || sample.contentHeight < requiredContentHeight - 0.5 {
                phase = .preparing(request)
                position.scrollTo(y: origin)
            } else {
                phase = .ready(request)
            }
        }
    }

    @discardableResult
    func begin(_ request: Request) -> Bool {
        guard phase == .ready(request) else { return false }
        phase = .editing(request)
        if abs(sample.position - request.target) > 0.5 {
            position.scrollTo(y: request.target)
        }
        return true
    }

    func measureKeypadHeight(_ height: CGFloat) {
        guard height > 0, abs(height - keypadHeight) > 0.5 else { return }
        let oldClearance = clearance
        keypadHeight = height
        guard case .editing(let previous) = phase else { return }
        let movement = max(0, previous.rowBottom - sample.position
            - (viewportBottom - height - BudgetLayout.assignmentScrollVisibilityMargin))
        let request = Request(
            categoryID: previous.categoryID, startsEditing: false,
            target: sample.position + movement,
            restoration: previous.restoration ?? (movement > 0.5 ? sample.position : nil),
            rowBottom: previous.rowBottom,
            requiredContentHeight: sample.contentHeight + clearance - oldClearance
        )
        phase = clearance > oldClearance ? .preparing(request) : .ready(request)
    }

    func close() {
        guard let request = phase.request else { return }
        if case .closing = phase { return }
        withAnimation(BudgetLayout.assignmentKeypadAnimation, completionCriteria: .removed) {
            beginClosing(request)
        } completion: {
            self.finishClosing(request)
        }
    }

    func beginClosing(_ request: Request) {
        guard phase.request == request else { return }
        let appliedClearance = min(clearance, max(0,
            sample.contentHeight - (request.requiredContentHeight - clearance)))
        let maximum = max(0, sample.maximum - appliedClearance)
        let target = min(request.restoration ?? sample.position, maximum)
        phase = .closing(request)
        position.scrollTo(y: max(0, target))
    }

    func finishClosing(_ request: Request) {
        guard phase == .closing(request) else { return }
        // Retiring offscreen clearance must not issue another scroll or interrupt the spring.
        phase = .idle
        keypadHeight = BudgetKeypadLayout.initialHeight
    }

    func cancelPendingPresentation() {
        phase = .idle
        keypadHeight = BudgetKeypadLayout.initialHeight
    }
}
