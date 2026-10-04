import Foundation
import Security
import Testing
@testable import Actualist

@MainActor
struct CredentialAvailabilityCacheTests {
    private func makeAppState(backend: FakeKeychainBackend) -> AppState {
        let defaults = UserDefaults(suiteName: "ActualistTests.CredentialCache.\(UUID().uuidString)")!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString,
                backend: backend
            )
        )
    }

    @Test func repeatedBodyReadsDoNotTouchKeychain() throws {
        let backend = FakeKeychainBackend()
        let appState = makeAppState(backend: backend)
        try appState.keychain.saveActualSyncToken("token")
        appState.refreshCredentialAvailability()
        let before = backend.copyCallCount

        for _ in 0..<50 {
            #expect(appState.credentialAvailability == .available)
            _ = appState.hasSyncCredentials
        }

        #expect(backend.copyCallCount == before)
    }

    @Test func unreadableKeychainIsCachedAsUnavailableNotAbsentAndRecovers() throws {
        let backend = FakeKeychainBackend()
        let appState = makeAppState(backend: backend)
        try appState.keychain.saveActualSyncToken("token")
        backend.copyFailureStatus = errSecInteractionNotAllowed

        appState.refreshCredentialAvailability()
        #expect(appState.credentialAvailability == .unavailable(.unavailable(errSecInteractionNotAllowed)))

        backend.copyFailureStatus = nil
        appState.refreshCredentialAvailability()
        #expect(appState.credentialAvailability == .available)
    }

    @Test func headersSummaryReadsKeychainOnceForUnchangedInputs() throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: backend)
        let store = LocalFirstActualStore(keychain: keychain)
        try store.saveCustomHTTPHeaders(.init(
            primary: try EndpointCustomHTTPHeaders(
                url: URL(string: "https://primary.example")!,
                headers: [.init(name: "X-Primary", value: "secret")]
            )
        ))
        let model = SettingsViewModel()
        model.serverURLString = "https://primary.example"

        #expect(model.customHeadersSummary(using: store) == "1 Configured")
        let before = backend.copyCallCount
        for _ in 0..<50 {
            #expect(model.customHeadersSummary(using: store) == "1 Configured")
        }
        #expect(backend.copyCallCount == before)

        try store.saveCustomHTTPHeaders(.init())
        #expect(model.customHeadersSummary(using: store) == "0 Configured")
    }

    @Test func unreadableHeadersAreNotCachedAsUnavailable() throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: backend)
        let store = LocalFirstActualStore(keychain: keychain)
        let model = SettingsViewModel()
        backend.copyFailureStatus = errSecInteractionNotAllowed

        #expect(model.customHeadersSummary(using: store) == "Unavailable")
        backend.copyFailureStatus = nil
        #expect(model.customHeadersSummary(using: store) == "0 Configured")
    }
}
