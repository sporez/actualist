import Foundation
import Testing
@testable import Actualist

@MainActor
struct EntityNotesSaveCancelTests {
    @Test func committedSaveReturnsTrueEvenWhenCancelledMidFlight() async throws {
        let target = try #require(ActualNoteTarget.category(id: "cat-1", title: "Groceries"))
        let repository = GatedSaveNotesRepository()
        let model = EntityNotesViewModel(target: target, budgetID: "budget", isPrivacyModeEnabled: false)
        await model.load(repository: repository)
        model.text = "Draft"

        let saving = Task { await model.save(repository: repository) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            repository.entered.trip()
            repository.release.trip()
        }
        defer { deadline.cancel(); saving.cancel(); repository.release.trip() }
        await repository.entered.wait()
        #expect(model.isSaving)

        model.cancel()
        repository.release.trip()
        let result = await saving.value

        // The write committed; reporting failure would make the caller retry
        // or hide a saved note.
        #expect(result)
        #expect(repository.saved == ["Draft"])
        #expect(model.phase == .idle)
    }
}

@MainActor
private final class GatedSaveNotesRepository: EntityNotesRepositoryProtocol {
    let entered = TestLatch()
    let release = TestLatch()
    var saved: [String] = []

    func entityNote(target: ActualNoteTarget, budgetID: String) async throws -> ActualNoteBody {
        ActualNoteBody(storedNote: "Original")
    }

    func setEntityNoteAndRefresh(target: ActualNoteTarget, userBody: String, budgetID: String) async throws {
        entered.trip()
        await release.wait()
        saved.append(userBody)
    }
}
