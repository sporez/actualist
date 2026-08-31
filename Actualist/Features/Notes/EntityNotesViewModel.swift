import Foundation
import Observation

@MainActor
@Observable
final class EntityNotesViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case editing(errorMessage: String?)
        case saving
        case privacy
    }

    let target: ActualNoteTarget
    let budgetID: String
    let isPrivacyModeEnabled: Bool
    var text = ""
    private(set) var phase: Phase

    private var generation = 0

    init(
        target: ActualNoteTarget,
        budgetID: String,
        isPrivacyModeEnabled: Bool
    ) {
        self.target = target
        self.budgetID = budgetID
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
        phase = isPrivacyModeEnabled ? .privacy : .idle
    }

    var isLoading: Bool { phase == .loading }
    var isSaving: Bool { phase == .saving }

    var canSave: Bool {
        if case .editing = phase {
            return true
        }
        return false
    }

    var errorMessage: String? {
        if case .editing(let errorMessage) = phase {
            return errorMessage
        }
        return nil
    }

    func load(repository: any EntityNotesRepositoryProtocol) async {
        guard !isPrivacyModeEnabled, phase == .idle else {
            return
        }
        generation += 1
        let requestGeneration = generation
        phase = .loading
        do {
            let body = try await repository.entityNote(target: target, budgetID: budgetID)
            guard requestGeneration == generation else {
                return
            }
            text = body.userBody
            phase = .editing(errorMessage: nil)
        } catch {
            guard requestGeneration == generation else {
                return
            }
            phase = .editing(errorMessage: error.localizedDescription)
        }
    }

    func save(repository: any EntityNotesRepositoryProtocol) async -> Bool {
        guard !isPrivacyModeEnabled, canSave else {
            return false
        }
        generation += 1
        let requestGeneration = generation
        phase = .saving
        do {
            try await repository.setEntityNoteAndRefresh(
                target: target,
                userBody: text,
                budgetID: budgetID
            )
            guard requestGeneration == generation else {
                return false
            }
            phase = .editing(errorMessage: nil)
            return true
        } catch {
            guard requestGeneration == generation else {
                return false
            }
            phase = .editing(errorMessage: error.localizedDescription)
            return false
        }
    }

    func cancel() {
        generation += 1
        text = ""
        phase = isPrivacyModeEnabled ? .privacy : .idle
    }
}
