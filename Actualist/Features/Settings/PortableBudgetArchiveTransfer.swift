import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What Budget & Data's Export row shares: a lazy portable budget ZIP.
///
/// The ZIP is not built when the row renders or is tapped. The share sheet
/// opens immediately and the system asks for the file only when a destination
/// needs it, which runs `exportArchive()` and so the store's existing portable
/// export. Each request writes its own plaintext archive into
/// `PortableExportFiles`, whose age-out removes it; nothing here deletes it,
/// because the receiver may still be copying after the request returns.
///
/// The item is bound to the budget it was created for.
/// `exportPortableBudgetArchive` refuses a budget that is no longer the open
/// one, so a budget switch while the sheet is open fails that request instead
/// of exporting the wrong budget. A failed request surfaces through the system
/// share sheet.
struct PortableBudgetArchiveTransfer: Transferable, Sendable {
    let budgetID: String
    /// Runs on the main actor when a destination requests the file, before the
    /// export starts (see `make`).
    let willExport: @MainActor @Sendable () -> Void
    let export: @MainActor @Sendable (_ budgetID: String) async throws -> URL

    /// Fixed, so the shared file never carries the budget's name (which may be
    /// masked by privacy display settings).
    static let suggestedFileName = "Budget Export"

    @MainActor
    static func make(
        budgetID: String,
        appState: AppState,
        activity: PortableBudgetExportActivity? = nil
    ) -> PortableBudgetArchiveTransfer {
        PortableBudgetArchiveTransfer(
            budgetID: budgetID,
            // The share sheet and its destinations can move the scene out of
            // .active, and the suppression must be in place before that.
            // SwiftUI has no sheet-presented callback for ShareLink, and a tap
            // gesture layered on it broke the row's hit target, so the first
            // request for the file is the trigger. ActualistApp clears it when
            // the scene next becomes active.
            willExport: { appState.beginAppInitiatedSystemUIPresentation() },
            export: { budgetID in
                activity?.begin()
                defer { activity?.end() }
                return try await appState.localFirstStore.exportPortableBudgetArchive(budgetID: budgetID)
            }
        )
    }

    func exportArchive() async throws -> URL {
        await willExport()
        return try await export(budgetID)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            // The receiver gets a copy; the original stays under age-out.
            SentTransferredFile(try await item.exportArchive(), allowAccessingOriginalFile: false)
        }
        .suggestedFileName(suggestedFileName)
    }

    nonisolated static let baseFooter = "Saves the open budget as a portable ZIP file you can share or import elsewhere. Your server data is not changed."

    /// Footer copy for the Export section. The ZIP is always plaintext, even
    /// when the budget is end-to-end encrypted on the server.
    nonisolated static func footerText(isBudgetEncrypted: Bool) -> String {
        guard isBudgetEncrypted else { return baseFooter }
        return baseFooter + " This export is not encrypted. Anyone with the file can read your budget."
    }
}

/// Whether the Export row should show its spinner. The share sheet takes
/// seconds to ask for the file after the tap, so the spinner starts at the
/// tap (`shareRequested`) and stays through the archive build. Builds are
/// counted because a destination can request the file more than once.
@MainActor @Observable
final class PortableBudgetExportActivity {
    private(set) var inFlightCount = 0
    private(set) var isAwaitingShareSheet = false
    private var awaitingTimeout: Task<Void, Never>?
    private let awaitingLimit: Duration

    init(awaitingLimit: Duration = .seconds(15)) {
        self.awaitingLimit = awaitingLimit
    }

    var isPreparing: Bool { inFlightCount > 0 || isAwaitingShareSheet }

    /// The row was tapped. If the share sheet never asks for the file, the
    /// spinner clears after `awaitingLimit`.
    func shareRequested() {
        isAwaitingShareSheet = true
        awaitingTimeout?.cancel()
        awaitingTimeout = Task { [weak self, awaitingLimit] in
            do { try await Task.sleep(for: awaitingLimit) } catch { return }
            self?.isAwaitingShareSheet = false
        }
    }

    func begin() { inFlightCount += 1 }

    func end() {
        inFlightCount = max(0, inFlightCount - 1)
        guard inFlightCount == 0 else { return }
        isAwaitingShareSheet = false
        awaitingTimeout?.cancel()
        awaitingTimeout = nil
    }
}
