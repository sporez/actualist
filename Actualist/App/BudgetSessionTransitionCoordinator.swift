import Foundation
import Observation

/// The single owner of budget-session transitions: selecting, restoring and
/// reimporting a budget, and the opens that Shortcuts, background refresh,
/// discovery and demo mode start. The store's session generation still keeps
/// stale work from publishing; this owner keeps competing callers from
/// cancelling each other into spurious errors.
///
/// - A request for the budget already in transition waits for it. The same
///   kind of request shares its result; another kind runs afterwards, against
///   the session the first one left (callers short-circuit an open budget).
/// - A request for a different budget, or a reimport against an open (and the
///   reverse), is refused while a transition is in flight. Discovery never
///   waits: the restore it may run inside could be waiting on that discovery.
/// - The owner task is unstructured, so a cancelled caller cannot abandon a
///   transition. Only `cancel()` (sign-out, erase, the onboarding open
///   timeout) cancels it.
@MainActor
@Observable
final class BudgetSessionTransitionCoordinator {
    enum Kind: Equatable {
        case select, restore, reimport, intent, background, discovery, demo
    }

    private struct Transition {
        let id: UUID
        let kind: Kind
        let budgetID: String
        let keepsShell: Bool
        let value: @MainActor () async -> any Sendable
        let cancel: () -> Void
    }

    @TaskLocal private static var ownerID: UUID?

    private var current: Transition?

    /// Requests waiting behind the transition in flight. Observable so tests
    /// can wait for a joined request deterministically.
    private(set) var waitingRequestCount = 0

    var isTransitionInFlight: Bool { current != nil }

    /// True while a transition could close or replace `budgetID`'s session:
    /// another budget's, or a reimport. A same-budget open leaves it in place.
    func isReplacingSession(of budgetID: String) -> Bool {
        guard let current else { return false }
        return current.budgetID != budgetID || current.kind == .reimport
    }

    /// A budget switch that keeps the current budget's shell on screen until
    /// the replacement opens or the previous budget is restored.
    var keepsShell: Bool { current?.keepsShell == true }

    /// Returns `nil` when the request is refused as busy.
    func run<Value: Sendable>(
        _ kind: Kind,
        budgetID: String,
        keepsShell: Bool = false,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value? {
        // Discovery and an auto-select can run inside a restore's owner task.
        if let ownerID = Self.ownerID, ownerID == current?.id {
            return await operation()
        }
        while let transition = current {
            guard transition.budgetID == budgetID,
                  (transition.kind == .reimport) == (kind == .reimport),
                  kind != .discovery else { return nil }
            waitingRequestCount += 1
            let value = await transition.value()
            waitingRequestCount -= 1
            if transition.kind == kind, let value = value as? Value { return value }
        }
        let id = UUID()
        let task = Task { @MainActor in
            let value = await Self.$ownerID.withValue(id) { await operation() }
            if current?.id == id { current = nil }
            return value
        }
        current = Transition(
            id: id, kind: kind, budgetID: budgetID, keepsShell: keepsShell,
            value: { await task.value }, cancel: { task.cancel() }
        )
        return await task.value
    }

    /// Throwing operations share the same admission; `nil` still means busy.
    func runThrowing<Value: Sendable>(
        _ kind: Kind,
        budgetID: String,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value? {
        let result = await run(kind, budgetID: budgetID) { () -> Result<Value, any Error> in
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        return try result?.get()
    }

    func cancel() {
        current?.cancel()
        current = nil
    }
}
