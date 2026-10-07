import Foundation
import Synchronization

/// Heartbeat of one budget open (concurrency 5.5c). The open reports progress
/// at each download chunk and stage boundary; the picker's watchdog treats a
/// whole window with none as a stall, so a slow but moving download on a poor
/// connection is not cut off by a wall-clock ceiling.
///
/// Reaches the open through a task-local: the session-transition owner task is
/// created inside the caller's context and inherits it. Code that runs on a
/// delegate queue captures `current` first.
final class BudgetOpenProgress: Sendable {
    @TaskLocal static var current: BudgetOpenProgress?

    private let state = Mutex((ticks: UInt64(0), stalled: false))

    func tick() {
        state.withLock { $0.ticks &+= 1 }
    }

    var ticks: UInt64 { state.withLock { $0.ticks } }

    /// Set by the watchdog before it cancels the open, so the picker can tell a
    /// stall from a cancellation by the caller.
    var didStall: Bool { state.withLock { $0.stalled } }

    func markStalled() {
        state.withLock { $0.stalled = true }
    }
}
