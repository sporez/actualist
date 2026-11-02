import CoreGraphics

/// All distances are points. Keep the physical tuning controls together.
struct BudgetMonthSwipePolicy {
    var edgeWidth: CGFloat = 20
    var recognitionDistance: CGFloat = 12
    var horizontalDominance: CGFloat = 1.5
    var commitFraction: CGFloat = 0.25
    var maximumCommitDistance: CGFloat = 110
    var settleDuration: Double = 0.34
    var springBounce: Double = 0.18

    enum Direction: Equatable {
        case previous, next
        var monthOffset: Int { self == .previous ? -1 : 1 }
        var translationSign: CGFloat { self == .previous ? 1 : -1 }
    }

    enum Recognition: Equatable {
        case pending
        case rejected
        case vertical
        case horizontal(Direction)
    }

    struct Drag: Equatable {
        var recognition: Recognition = .pending
        var translation: CGFloat = 0
        var viewport: CGSize?
        var revision: Int?
    }

    func update(_ drag: inout Drag, start: CGPoint, translation: CGSize, viewport: CGSize, enabled: Bool, revision: Int = 0) {
        // A vertical drag belongs to the scroll view. Nothing may reject it, because
        // a rejected drag disables the scroll view under the finger.
        if drag.recognition == .vertical { return }
        // The viewport's height follows the navigation bar as the budget scrolls,
        // so only a width change is a resize, and only the touch-down must be inside.
        guard enabled, viewport.width > edgeWidth * 2,
              drag.revision == nil || drag.revision == revision,
              drag.viewport == nil || drag.viewport?.width == viewport.width,
              drag.viewport != nil || (start.y >= 0 && start.y <= viewport.height) else {
            drag.recognition = .rejected
            return
        }
        drag.viewport = viewport
        drag.revision = revision
        guard drag.recognition != .rejected else { return }
        if drag.recognition == .pending {
            guard max(abs(translation.width), abs(translation.height)) >= recognitionDistance else { return }
            guard abs(translation.width) >= horizontalDominance * abs(translation.height) else {
                drag.recognition = .vertical
                return
            }
            let direction: Direction
            if (0...edgeWidth).contains(start.x) { direction = .previous }
            else if start.x >= viewport.width - edgeWidth { direction = .next }
            else { drag.recognition = .rejected; return }
            guard translation.width * direction.translationSign >= recognitionDistance else {
                drag.recognition = .rejected
                return
            }
            drag.recognition = .horizontal(direction)
        }
        drag.translation = translation.width
    }

    func suppressesControls(_ drag: Drag) -> Bool {
        switch drag.recognition {
        case .horizontal, .rejected: true
        case .pending, .vertical: false
        }
    }

    func committedDirection(_ drag: Drag) -> Direction? {
        guard case .horizontal(let direction) = drag.recognition, let viewport = drag.viewport,
              drag.translation * direction.translationSign >= min(viewport.width * commitFraction, maximumCommitDistance)
        else { return nil }
        return direction
    }

    func previewOffset(_ drag: Drag) -> CGFloat {
        guard case .horizontal(let direction) = drag.recognition else { return 0 }
        let inward = max(0, drag.translation * direction.translationSign)
        return direction.translationSign * min(inward, drag.viewport?.width ?? 0)
    }
}
