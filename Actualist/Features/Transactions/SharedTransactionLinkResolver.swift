import Foundation
import Observation

/// Reads and sync the resolver needs, so tests can stand in for the store.
@MainActor
protocol SharedTransactionLinkSource {
    func lookUpSharedTransaction(budgetID: String, id: String) async throws -> SharedTransactionLookup
    /// Joins the sync already running for this budget, or starts one. `false` when it failed.
    func syncForSharedTransaction(budgetID: String) async -> Bool
}

struct AppSharedTransactionLinkSource: SharedTransactionLinkSource {
    let appState: AppState

    func lookUpSharedTransaction(budgetID: String, id: String) async throws -> SharedTransactionLookup {
        try await appState.localFirstStore.sharedTransactionLookup(budgetID: budgetID, id: id)
    }

    func syncForSharedTransaction(budgetID: String) async -> Bool {
        await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
    }
}

/// Turns an opened shared-transaction link into the transaction to edit.
///
/// A device that hasn't synced lately is the normal case: the link usually
/// names a transaction made after this device last pulled. So a local miss
/// waits for one sync, joining the one opening the app started, before it
/// says the transaction isn't here.
@MainActor
@Observable
final class SharedTransactionLinkResolver {
    enum Failure: Equatable {
        case notOnDevice
        case serverUnreachable
        case deleted
        case unreadable

        var title: String {
            switch self {
            case .notOnDevice: "Transaction Not Found"
            case .serverUnreachable: "Couldn't Reach Your Server"
            case .deleted: "Transaction Deleted"
            case .unreadable: "Couldn't Open Transaction"
            }
        }

        var message: String {
            switch self {
            case .notOnDevice:
                "This transaction isn't on this device. It may be in another budget or not synced yet."
            case .serverUnreachable:
                "This transaction isn't on this device yet. Check your connection and open the link again."
            case .deleted:
                "This transaction was deleted."
            case .unreadable:
                "Actualist couldn't read this budget. Try again."
            }
        }
    }

    enum State: Equatable {
        case idle
        case lookingUp
        /// Shown to the user: a local miss is waiting for a sync.
        case syncing
        case failed(Failure)
    }

    private(set) var state: State = .idle
    private var generation = 0

    var failure: Failure? {
        if case .failed(let failure) = state { return failure }
        return nil
    }

    /// The live transaction to edit, or `nil` after a failure, a cancel, or a
    /// newer link replaced this one.
    func resolve(
        transactionID: String,
        budgetID: String,
        source: some SharedTransactionLinkSource
    ) async -> ActualTransaction? {
        generation &+= 1
        let current = generation
        state = .lookingUp

        let first: SharedTransactionLookup
        do {
            first = try await source.lookUpSharedTransaction(budgetID: budgetID, id: transactionID)
        } catch {
            return finish(current, with: .unreadable)
        }
        guard current == generation else { return nil }
        switch first {
        case .found(let transaction): return finish(current, with: transaction)
        case .deleted: return finish(current, with: .deleted)
        case .missing: break
        }

        state = .syncing
        let synced = await source.syncForSharedTransaction(budgetID: budgetID)
        guard current == generation else { return nil }

        let second: SharedTransactionLookup
        do {
            second = try await source.lookUpSharedTransaction(budgetID: budgetID, id: transactionID)
        } catch {
            return finish(current, with: .unreadable)
        }
        switch second {
        case .found(let transaction): return finish(current, with: transaction)
        case .deleted: return finish(current, with: .deleted)
        case .missing: return finish(current, with: synced ? .notOnDevice : .serverUnreachable)
        }
    }

    /// Drops an in-flight resolve (user cancel, budget switch, sign-out).
    func cancel() {
        generation &+= 1
        state = .idle
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private func finish(_ current: Int, with transaction: ActualTransaction) -> ActualTransaction? {
        guard current == generation else { return nil }
        state = .idle
        return transaction
    }

    private func finish(_ current: Int, with failure: Failure) -> ActualTransaction? {
        guard current == generation else { return nil }
        state = .failed(failure)
        return nil
    }
}
