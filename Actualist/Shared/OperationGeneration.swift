import Foundation

/// A counter that marks work as stale once newer work has started or the owner
/// has invalidated it. Call `begin()` when starting or cancelling work and keep
/// the result; check `isCurrent(_:requiringNotCancelled:)` after each await.
/// A site that must also stop when its own task was cancelled passes `true`.
struct OperationGeneration {
    private(set) var current = 0

    @discardableResult
    mutating func begin() -> Int {
        current &+= 1
        return current
    }

    func isCurrent(_ candidate: Int, requiringNotCancelled: Bool) -> Bool {
        current == candidate && !(requiringNotCancelled && Task.isCancelled)
    }
}
