import Foundation
import Testing
@testable import Actualist

/// Empty-budget picker coverage: the offer decision (successful zero-budget
/// discovery vs list failure/cancellation vs a populated picker vs demo mode),
/// the create-input interpretation, and the create workflow's handoff to the
/// existing selection path. The coordinator's store and selection steps are
/// injected fakes; no server is contacted and no budget files are written.
@MainActor
struct EmptyBudgetPickerCoordinatorTests {
    // MARK: - Fixtures

    private func makeAppState() -> AppState {
        let defaults = UserDefaults(
            suiteName: "ActualistTests.EmptyBudgetPicker.\(UUID().uuidString)"
        )!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString,
                backend: FakeKeychainBackend()
            )
        )
    }

    private func makeBudget(
        fileID: String,
        groupID: String? = nil
    ) -> ActualBudget {
        ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: groupID,
            name: "Budget \(fileID)",
            state: nil
        )
    }

    private final class SelectionRecorder {
        var budgets: [ActualBudget] = []
        var inputs: [EmptyBudgetCreateInput] = []
        var importedArchiveURLs: [URL] = []
    }

    // MARK: - Offer decision (empty vs failure vs populated vs demo)

    @Test func successfulZeroBudgetDiscoveryOffersEmptyBudgetActions() {
        let offer = EmptyBudgetPickerOffer.decide(
            discoverySucceeded: true,
            isDemoMode: false,
            budgetCount: 0
        )
        #expect(offer == .offered)
    }

    @Test func listFailureNeverCountsAsEmptyServer() {
        let offer = EmptyBudgetPickerOffer.decide(
            discoverySucceeded: false,
            isDemoMode: false,
            budgetCount: 0
        )
        #expect(offer == .hidden(.discoveryIncomplete))
    }

    @Test func singleBudgetDoesNotOfferAndDoesNotFightAutoSelect() {
        let offer = EmptyBudgetPickerOffer.decide(
            discoverySucceeded: true,
            isDemoMode: false,
            budgetCount: 1
        )
        #expect(offer == .hidden(.budgetsPresent))
    }

    @Test func populatedPickerDoesNotOffer() {
        let offer = EmptyBudgetPickerOffer.decide(
            discoverySucceeded: true,
            isDemoMode: false,
            budgetCount: 4
        )
        #expect(offer == .hidden(.budgetsPresent))
    }

    @Test func demoModeNeverOffersEvenAfterSuccessfulEmptyDiscovery() {
        let offer = EmptyBudgetPickerOffer.decide(
            discoverySucceeded: true,
            isDemoMode: true,
            budgetCount: 0
        )
        #expect(offer == .hidden(.demoMode))
    }

    @Test func offerCombinesDiscoveryOutcomeWithLiveSessionState() {
        let appState = makeAppState()
        let coordinator = EmptyBudgetPickerCoordinator()

        // No discovery attempt yet: nothing is offered.
        #expect(coordinator.offer(using: appState) == .hidden(.discoveryIncomplete))

        coordinator.recordDiscovery(succeeded: false)
        #expect(coordinator.offer(using: appState) == .hidden(.discoveryIncomplete))

        coordinator.recordDiscovery(succeeded: true)
        #expect(coordinator.offer(using: appState) == .offered)

        // Demo mode is never an empty server.
        appState.settings.selectedLocalFirstFileID = DemoBudget.fileID
        #expect(coordinator.offer(using: appState) == .hidden(.demoMode))
    }

    @Test func offerHidesWhenDiscoveryReturnsBudgets() {
        let appState = makeAppState()
        let coordinator = EmptyBudgetPickerCoordinator()
        coordinator.recordDiscovery(succeeded: true)
        appState.budgets = [makeBudget(fileID: "file-one")]

        #expect(coordinator.offer(using: appState) == .hidden(.budgetsPresent))
    }

    // MARK: - Create input interpretation

    @Test func createInputKeepsRequestedEncryptionAndRefusesEmptyPassword() {
        let encrypted = EmptyBudgetCreateInput.make(
            budgetName: "  Fresh Budget  ",
            encryptionWanted: true,
            encryptionPassword: "  secret  "
        )
        #expect(encrypted.budgetName == "  Fresh Budget  ")
        #expect(encrypted.encryptionPassword == "secret")
        #expect(encrypted.isSubmittable)

        // Encryption requested with no password is not submittable; it must
        // never silently downgrade to a plaintext budget.
        let emptyPassword = EmptyBudgetCreateInput.make(
            budgetName: "Fresh Budget",
            encryptionWanted: true,
            encryptionPassword: "   "
        )
        #expect(emptyPassword.encryptionPassword?.isEmpty == true)
        #expect(!emptyPassword.isSubmittable)

        let plaintext = EmptyBudgetCreateInput.make(
            budgetName: "Fresh Budget",
            encryptionWanted: false,
            encryptionPassword: "ignored"
        )
        #expect(plaintext.encryptionPassword == nil)
        #expect(plaintext.isSubmittable)

        #expect(!EmptyBudgetCreateInput.make(
            budgetName: "   ",
            encryptionWanted: false,
            encryptionPassword: ""
        ).isSubmittable)
    }

    // MARK: - Create workflow handoff

    @Test func createSuccessHandsCompletedIdentityToSelection() async throws {
        let appState = makeAppState()
        let recorder = SelectionRecorder()
        let coordinator = EmptyBudgetPickerCoordinator(workflows: .init(
            createNewBudget: { _, input in
                recorder.inputs.append(input)
                return NewBudgetCreation(
                    fileID: "file-new",
                    groupID: "group-new",
                    budgetName: "Fresh Budget",
                    encryptionKeyID: nil
                )
            },
            selectBudget: { appState, budget in
                recorder.budgets.append(budget)
                appState.settings.selectedBudgetID = budget.syncID
            }
        ))

        let input = EmptyBudgetCreateInput.make(
            budgetName: "Fresh Budget",
            encryptionWanted: false,
            encryptionPassword: ""
        )
        await coordinator.createBudget(input, using: appState)

        #expect(recorder.inputs == [input])
        #expect(recorder.budgets.count == 1)
        let identity = try #require(recorder.budgets.first)
        #expect(identity.localFirstFileID == "file-new")
        #expect(identity.groupId == "group-new")
        #expect(identity.name == "Fresh Budget")
        #expect(appState.settings.selectedBudgetID == identity.syncID)
        #expect(coordinator.phase == .idle)
    }

    @Test func createFailureDoesNotCallSelection() async {
        let appState = makeAppState()
        let recorder = SelectionRecorder()
        let coordinator = EmptyBudgetPickerCoordinator(workflows: .init(
            createNewBudget: { _, _ in
                throw NewBudgetError.invalidBudgetName
            },
            selectBudget: { _, budget in
                recorder.budgets.append(budget)
            }
        ))

        await coordinator.createBudget(
            EmptyBudgetCreateInput.make(
                budgetName: "Fresh Budget",
                encryptionWanted: false,
                encryptionPassword: ""
            ),
            using: appState
        )

        #expect(recorder.budgets.isEmpty)
        #expect(appState.settings.selectedBudgetID == nil)
        #expect(
            coordinator.phase
                == .failed(message: NewBudgetError.invalidBudgetName.localizedDescription)
        )
    }

    @Test func selectionFailureAfterConfirmedCreateSurfacesCoordinatorFailure() async {
        let appState = makeAppState()
        let coordinator = EmptyBudgetPickerCoordinator(workflows: .init(
            createNewBudget: { _, _ in
                NewBudgetCreation(
                    fileID: "file-new",
                    groupID: nil,
                    budgetName: "Fresh Budget",
                    encryptionKeyID: nil
                )
            },
            selectBudget: { appState, _ in
                appState.lastErrorMessage = "Open failed"
            }
        ))

        await coordinator.createBudget(
            EmptyBudgetCreateInput.make(
                budgetName: "Fresh Budget",
                encryptionWanted: false,
                encryptionPassword: ""
            ),
            using: appState
        )

        #expect(appState.settings.selectedBudgetID == nil)
        #expect(coordinator.phase == .failed(message: "Open failed"))
    }

    // MARK: - Import workflow handoff

    @Test func importSuccessHandsMintedIdentityToSelection() async throws {
        let appState = makeAppState()
        let recorder = SelectionRecorder()
        let coordinator = EmptyBudgetPickerCoordinator(workflows: .init(
            createNewBudget: { _, _ in
                NewBudgetCreation(
                    fileID: "file-unused",
                    groupID: nil,
                    budgetName: "Unused",
                    encryptionKeyID: nil
                )
            },
            importPortableBudget: { _, archiveURL in
                recorder.importedArchiveURLs.append(archiveURL)
                return NewBudgetCreation(
                    fileID: "file-imported",
                    groupID: "group-imported",
                    budgetName: "Imported Budget",
                    encryptionKeyID: nil
                )
            },
            selectBudget: { appState, budget in
                recorder.budgets.append(budget)
                appState.settings.selectedBudgetID = budget.syncID
            }
        ))

        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "import-coordinator-\(UUID().uuidString).zip")
        await coordinator.importBudget(at: archiveURL, using: appState)

        #expect(recorder.importedArchiveURLs == [archiveURL])
        #expect(recorder.budgets.count == 1)
        let identity = try #require(recorder.budgets.first)
        #expect(identity.localFirstFileID == "file-imported")
        #expect(identity.groupId == "group-imported")
        #expect(identity.name == "Imported Budget")
        #expect(appState.settings.selectedBudgetID == identity.syncID)
        #expect(coordinator.phase == .idle)
    }

    @Test func importFailureSurfacesPhaseAndDoesNotSelect() async {
        let appState = makeAppState()
        let recorder = SelectionRecorder()
        let coordinator = EmptyBudgetPickerCoordinator(workflows: .init(
            createNewBudget: { _, _ in
                NewBudgetCreation(
                    fileID: "file-unused",
                    groupID: nil,
                    budgetName: "Unused",
                    encryptionKeyID: nil
                )
            },
            importPortableBudget: { _, _ in
                throw PortableImportFailure()
            },
            selectBudget: { _, budget in
                recorder.budgets.append(budget)
            }
        ))

        await coordinator.importBudget(
            at: URL(fileURLWithPath: "/nonexistent/portable.zip"),
            using: appState
        )

        #expect(recorder.budgets.isEmpty)
        #expect(recorder.importedArchiveURLs.isEmpty)
        #expect(appState.settings.selectedBudgetID == nil)
        #expect(coordinator.phase == .failed(message: "Import failed"))
    }

    @Test func createEntryHoldsWhileImportIsRunning() async {
        let appState = makeAppState()
        let recorder = SelectionRecorder()
        let importStarted = TestLatch()
        let releaseImport = TestLatch()
        let coordinator = EmptyBudgetPickerCoordinator(workflows: .init(
            createNewBudget: { _, _ in
                NewBudgetCreation(
                    fileID: "file-new",
                    groupID: nil,
                    budgetName: "Fresh Budget",
                    encryptionKeyID: nil
                )
            },
            importPortableBudget: { _, _ in
                importStarted.trip()
                await releaseImport.wait()
                return NewBudgetCreation(
                    fileID: "file-imported",
                    groupID: nil,
                    budgetName: "Imported Budget",
                    encryptionKeyID: nil
                )
            },
            selectBudget: { appState, budget in
                recorder.budgets.append(budget)
                appState.settings.selectedBudgetID = budget.syncID
            }
        ))

        let runningImport = Task {
            await coordinator.importBudget(
                at: URL(fileURLWithPath: "/nonexistent/portable.zip"),
                using: appState
            )
        }
        await importStarted.wait()

        // While the import runs, the create entry point returns immediately
        // without starting a second workflow or touching the selection.
        await coordinator.createBudget(
            EmptyBudgetCreateInput.make(
                budgetName: "Fresh Budget",
                encryptionWanted: false,
                encryptionPassword: ""
            ),
            using: appState
        )
        #expect(recorder.budgets.isEmpty)
        #expect(coordinator.phase == .importing)

        releaseImport.trip()
        await runningImport.value

        #expect(recorder.budgets.count == 1)
        #expect(recorder.budgets.first?.localFirstFileID == "file-imported")
        #expect(coordinator.phase == .idle)
    }
}

/// A deterministic import failure with a stable user-facing message.
private struct PortableImportFailure: LocalizedError {
    var errorDescription: String? { "Import failed" }
}
