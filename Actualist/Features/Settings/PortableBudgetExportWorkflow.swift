import Foundation
import Observation

/// Budget & Data settings export state machine: drives the store's portable
/// export and holds the produced archive URL for sharing. The view only
/// renders this state.
@MainActor
@Observable
final class PortableBudgetExportWorkflow {
    enum State: Equatable {
        case idle
        case exporting
        case ready(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var generation = 0

    func export(budgetID: String, store: LocalFirstActualStore) async {
        generation &+= 1
        let requestGeneration = generation
        state = .exporting
        do {
            let archiveURL = try await store.exportPortableBudgetArchive(budgetID: budgetID)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            state = .ready(archiveURL)
        } catch {
            guard requestGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            state = .failed("The export could not be created. Your budget has not been changed.")
        }
    }

    func reset() {
        generation &+= 1
        state = .idle
    }
}
