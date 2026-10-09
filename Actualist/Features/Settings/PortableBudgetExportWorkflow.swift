import Foundation
import Observation

/// Budget & Data's export: the screen builds the ZIP when it opens (and again
/// when the open budget changes), so Share Budget ZIP is one tap on a ready plain
/// file. A ShareLink over a custom `Transferable` took about five seconds to
/// open on device even with the file ready; a plain file URL opens at once
/// (device A/B, 2026-10-09).
///
/// Each prepare gets a generation. A superseded or cancelled build discards
/// its archive, and `reset` (leaving the screen, switching budgets) discards
/// the ready one.
@MainActor
@Observable
final class PortableBudgetExportWorkflow {
    enum State: Equatable {
        case idle
        case preparing(budgetID: String)
        case ready(budgetID: String, archiveURL: URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let files: PortableExportFiles
    @ObservationIgnored private var generation = 0

    init(files: PortableExportFiles = PortableExportFiles()) {
        self.files = files
    }

    var isPreparing: Bool {
        if case .preparing = state { return true }
        return false
    }

    /// The ready archive for `budgetID`, or nil when it belongs to another
    /// budget or isn't built.
    func readyArchive(for budgetID: String) -> URL? {
        guard case .ready(let readyBudgetID, let url) = state, readyBudgetID == budgetID else { return nil }
        return url
    }

    func prepare(
        budgetID: String,
        export: @MainActor (_ budgetID: String) async throws -> URL
    ) async {
        generation &+= 1
        let requestGeneration = generation
        discardReadyArchive()
        state = .preparing(budgetID: budgetID)
        do {
            let archiveURL = try await export(budgetID)
            guard requestGeneration == generation, !Task.isCancelled else {
                files.discard(archiveURL)
                // A superseding request owns the state; otherwise do not
                // strand `.preparing` after a cancelled task.
                if requestGeneration == generation { state = .idle }
                return
            }
            state = .ready(budgetID: budgetID, archiveURL: archiveURL)
        } catch {
            guard requestGeneration == generation else { return }
            guard !Task.isCancelled, !error.isCancellation else {
                state = .idle
                return
            }
            state = .failed(String(localized: "The export could not be created. Your budget has not been changed."))
        }
    }

    /// Removes a ready archive and invalidates a build in flight.
    func reset() {
        generation &+= 1
        discardReadyArchive()
        state = .idle
    }

    private func discardReadyArchive() {
        if case .ready(_, let url) = state {
            files.discard(url)
        }
    }

    nonisolated static let baseFooter = "Saves the open budget as a portable ZIP file you can share or import elsewhere. Your server data is not changed."

    /// Footer copy for the Export section. The ZIP is always plaintext, even
    /// when the budget is end-to-end encrypted on the server.
    nonisolated static func footerText(isBudgetEncrypted: Bool) -> String {
        guard isBudgetEncrypted else { return baseFooter }
        return baseFooter + " This export is not encrypted. Anyone with the file can read your budget."
    }
}
