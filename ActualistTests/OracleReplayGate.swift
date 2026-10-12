import Foundation
import Synchronization
@testable import Actualist

/// Bounds how many oracle replay cases build and write their throwaway budget
/// database at once. Swift Testing starts every argument of a parameterized
/// test together; each replay case creates a database file and suspends on its
/// own GRDB queue, so hundreds of cases otherwise write to disk at the same time.
/// A sampled full run showed about 470 threads, most in `pwrite`, inside
/// `BankSyncOracleReplay.seed` and `RuleOracleReplay.seed`. Every other test in
/// the host stalled behind that I/O until a time-limited test expired and the
/// host was replaced, dropping the tests still running in it.
///
/// Waiting cases suspend without holding a thread. A permit is always released
/// by its holder's `defer`, so a waiter cannot be stranded; cancellation while
/// waiting is not observed, because the wait ends when any running case ends.
final class OracleReplayGate: Sendable {
    static let shared = OracleReplayGate(limit: 4)

    /// Release exactly once, from a `defer` right after `acquire()`.
    struct Permit {
        fileprivate let gate: OracleReplayGate

        func release() {
            gate.release()
        }
    }

    private struct State {
        var available: Int
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(limit: Int) {
        state = Mutex(State(available: limit))
    }

    func acquire() async -> Permit {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = state.withLock { state -> Bool in
                guard state.available > 0 else {
                    state.waiters.append(continuation)
                    return false
                }
                state.available -= 1
                return true
            }
            if granted { continuation.resume() }
        }
        return Permit(gate: self)
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.available += 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// Opens oracle replay databases off the main actor. The replay helpers are
/// `@MainActor`, so with approachable concurrency their synchronous file work
/// (starter schema, compatibility passes, fsyncs) otherwise runs on the main
/// thread and delays every main-actor test in the host.
enum OracleReplayDatabase {
    @concurrent
    static func starter(at url: URL, localNodeID: String) async throws -> BudgetDatabase {
        _ = try BudgetDatabase.makeNewBudgetStarterDatabase(at: url)
        return try BudgetDatabase(databaseURL: url, localNodeID: localNodeID)
    }

    @concurrent
    static func open(at url: URL, localNodeID: String) async throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: url, localNodeID: localNodeID)
    }
}
