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
    @ObservationIgnored private let files: PortableExportFiles
    @ObservationIgnored private var generation = 0

    init(files: PortableExportFiles = PortableExportFiles()) {
        self.files = files
    }

    func export(budgetID: String, store: LocalFirstActualStore) async {
        generation &+= 1
        let requestGeneration = generation
        discardReadyArchive()
        state = .exporting
        do {
            let archiveURL = try await store.exportPortableBudgetArchive(budgetID: budgetID)
            guard requestGeneration == generation, !Task.isCancelled else {
                files.discard(archiveURL)
                return
            }
            state = .ready(archiveURL)
        } catch {
            guard requestGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            state = .failed("The export could not be created. Your budget has not been changed.")
        }
    }

    nonisolated static let baseFooter = "Saves the open budget as a portable ZIP file you can share or import elsewhere. Your server data is not changed."

    /// Footer copy for the Export section. The ZIP is always plaintext, even
    /// when the budget is end-to-end encrypted on the server.
    nonisolated static func footerText(isBudgetEncrypted: Bool) -> String {
        guard isBudgetEncrypted else { return baseFooter }
        return baseFooter + " This export is not encrypted. Anyone with the file can read your budget."
    }

    /// Removes the shared archive on reset, re-export and budget switch.
    func reset() {
        generation &+= 1
        discardReadyArchive()
        state = .idle
    }

    private func discardReadyArchive() {
        if case .ready(let url) = state {
            files.discard(url)
        }
    }
}
