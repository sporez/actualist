import Foundation
import Security
import Testing
@testable import Actualist

/// Erase Local Data deletes the budget files first and runs every Keychain
/// removal even after one fails, then reports each part it could not remove.
@MainActor
struct LocalDataEraseTests {
    private struct Probe: Error {}

    @Test func runAllRunsEveryStepAndNamesEachFailure() {
        var ran: [LocalDataEraseError.Part] = []
        #expect(throws: LocalDataEraseError(failedParts: [.syncToken, .customHeaders])) {
            try LocalDataEraseError.runAll([
                (.budgetFiles, { ran.append(.budgetFiles) }),
                (.syncToken, { ran.append(.syncToken); throw Probe() }),
                (.encryptionKeys, { ran.append(.encryptionKeys) }),
                (.customHeaders, { ran.append(.customHeaders); throw Probe() })
            ])
        }
        #expect(ran == [.budgetFiles, .syncToken, .encryptionKeys, .customHeaders])
    }

    @Test func runAllSucceedsWhenEveryStepDoes() throws {
        try LocalDataEraseError.runAll([(.budgetFiles, {}), (.syncToken, {})])
    }

    @Test func messageNamesTheFailedParts() {
        let message = LocalDataEraseError(failedParts: [.syncToken, .simpleFINAccess]).userFacingMessage
        #expect(message?.contains("the server sign-in") == true)
        #expect(message?.contains("the SimpleFIN access key") == true)
        #expect(message?.contains("the downloaded budgets") == false)
    }

    @Test func lockedKeychainStillDeletesBudgetFilesAndReportsTheFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LocalDataErase-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "LocalDataEraseTests.\(UUID().uuidString)"))
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests", account: UUID().uuidString, backend: backend
        )
        try keychain.saveActualSyncToken("token")
        let fileManager = BudgetFileManager(applicationSupportURL: root)
        let budgetDirectory = try fileManager.budgetDirectory(fileID: "file-a")
        try FileManager.default.createDirectory(at: budgetDirectory, withIntermediateDirectories: true)
        let state = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: keychain,
            localFirstStore: LocalFirstActualStore(keychain: keychain, fileManager: fileManager),
            applicationBadgeUpdater: { _ in }
        )
        state.settings.localFirstServerURLString = "https://actual.example.com"
        backend.deleteFailureStatus = errSecInteractionNotAllowed

        await state.disconnectAndEraseLocalData()

        #expect(!FileManager.default.fileExists(atPath: budgetDirectory.path))
        let message = try #require(state.lastErrorMessage)
        #expect(message.contains("the server sign-in"))
        #expect(!message.contains("the downloaded budgets"))
        // A failed erase keeps the connection so it can be retried.
        #expect(state.settings.localFirstServerURLString == "https://actual.example.com")

        backend.deleteFailureStatus = nil
        await state.disconnectAndEraseLocalData()

        #expect(try keychain.readActualSyncToken() == nil)
        #expect(state.settings.localFirstServerURLString.isEmpty)
    }
}
