import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What Budget & Data's Share Budget ZIP row shares: an archive that
/// `PortableBudgetExportWorkflow` already built. The share sheet gets a ready
/// file, so it opens without waiting on the export.
///
/// The receiver gets a copy (`allowAccessingOriginalFile: false`); the
/// original stays in `PortableExportFiles` until the workflow discards it or
/// age-out removes it.
struct PortableBudgetArchiveTransfer: Transferable, Sendable {
    let archiveURL: URL
    /// Runs on the main actor when a destination requests the file (see `make`).
    let willExport: @MainActor @Sendable () -> Void

    /// Fixed, so the shared file never carries the budget's name (which may be
    /// masked by privacy display settings).
    static let suggestedFileName = "Budget Export"

    @MainActor
    static func make(archiveURL: URL, appState: AppState) -> PortableBudgetArchiveTransfer {
        PortableBudgetArchiveTransfer(
            archiveURL: archiveURL,
            // The share sheet and its destinations can move the scene out of
            // .active, and the suppression must be in place before that.
            // SwiftUI has no sheet-presented callback for ShareLink, and a tap
            // gesture layered on it broke the row's hit target, so the first
            // request for the file is the trigger. ActualistApp clears it when
            // the scene next becomes active.
            willExport: { appState.beginAppInitiatedSystemUIPresentation() }
        )
    }

    func exportArchive() async -> URL {
        await willExport()
        return archiveURL
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            SentTransferredFile(await item.exportArchive(), allowAccessingOriginalFile: false)
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
