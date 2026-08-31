import Foundation

@MainActor
protocol EntityNotesRepositoryProtocol: Sendable {
    func entityNote(
        target: ActualNoteTarget,
        budgetID: String
    ) async throws -> ActualNoteBody

    func setEntityNoteAndRefresh(
        target: ActualNoteTarget,
        userBody: String,
        budgetID: String
    ) async throws
}
