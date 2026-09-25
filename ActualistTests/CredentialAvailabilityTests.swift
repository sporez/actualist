import Foundation
import Security
import Testing
@testable import Actualist

@MainActor
struct CredentialAvailabilityTests {
    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func readFailuresAreNotAbsence(status: OSStatus) throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: backend)
        try keychain.saveActualSyncToken("synthetic-token")
        try keychain.saveSimpleFINAccessURL("https://user:secret@bridge.example/user")
        try keychain.saveLocalFirstEncryptionKey(Data(repeating: 1, count: 32), fileID: "file", keyID: "key")
        let headers = CustomHTTPHeaderConfiguration(primary: try EndpointCustomHTTPHeaders(
            url: URL(string: "https://server.example")!,
            headers: [.init(name: "X-Test", value: "synthetic-header")]
        ))
        try keychain.saveCustomHTTPHeaders(headers)
        let original = backend.storedItemAttributes(service: keychain.service)

        backend.copyFailureStatus = status
        #expect(throws: KeychainReadError.unavailable(status)) { try keychain.readActualSyncToken() }
        #expect(throws: KeychainReadError.unavailable(status)) { try keychain.readSimpleFINAccessURL() }
        #expect(throws: KeychainReadError.unavailable(status)) {
            try keychain.readLocalFirstEncryptionKey(fileID: "file", keyID: "key")
        }
        #expect(throws: KeychainReadError.unavailable(status)) { try keychain.readCustomHTTPHeaders() }
        #expect(AppSessionRecovery.credentialAvailability(keychain: keychain) == .unavailable(.unavailable(status)))
        backend.copyFailureStatus = nil
        #expect(backend.storedItemAttributes(service: keychain.service).count == original.count)
        #expect(try keychain.readActualSyncToken() == "synthetic-token")
        #expect(try keychain.readSimpleFINAccessURL() != nil)
        #expect(try keychain.readLocalFirstEncryptionKey(fileID: "file", keyID: "key") == Data(repeating: 1, count: 32))
        #expect(try keychain.readCustomHTTPHeaders() == headers)
    }

    @Test func absentAndUnreadableRemainDistinct() throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: backend)
        #expect(AppSessionRecovery.credentialAvailability(keychain: keychain) == .absent)
        #expect(try keychain.readActualSyncToken() == nil)
        #expect(try keychain.readSimpleFINAccessURL() == nil)
        #expect(try keychain.readLocalFirstEncryptionKey(fileID: "file", keyID: "key") == nil)
        #expect(try keychain.readCustomHTTPHeadersIfPresent() == nil)
        try keychain.saveActualSyncToken("  ")
        try keychain.saveSimpleFINAccessURL("malformed")
        try keychain.saveLocalFirstEncryptionKey(Data([1, 2]), fileID: "file", keyID: "key")
        #expect(throws: KeychainReadError.unreadable) { try keychain.readActualSyncToken() }
        #expect(throws: KeychainReadError.unreadable) { try keychain.readSimpleFINAccessURL() }
        #expect(throws: KeychainReadError.unreadable) {
            try keychain.readLocalFirstEncryptionKey(fileID: "file", keyID: "key")
        }
        #expect(AppSessionRecovery.credentialAvailability(keychain: keychain) == .unavailable(.unreadable))

        let malformedHeaders: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychain.service,
            kSecAttrAccount as String: "custom-http-headers",
            kSecValueData as String: Data("{".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        #expect(backend.add(malformedHeaders as CFDictionary, result: nil) == errSecSuccess)
        #expect(throws: KeychainReadError.unreadable) { try keychain.readCustomHTTPHeadersIfPresent() }
    }

    @Test func noSelectionWithUnavailableCredentialIsRecoverableInsteadOfOnboarding() throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: backend)
        try keychain.saveActualSyncToken("synthetic-token")
        backend.copyFailureStatus = errSecAuthFailed
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settings = AppSettingsStore(defaults: defaults)
        settings.save(AppSettings(localFirstServerURLString: "https://synthetic.invalid"))
        let state = AppState(settingsStore: settings, keychain: keychain)
        #expect(state.setupPhase == .credentialUnavailable)
        #expect(state.credentialRecoveryMessage != nil)
        #expect(!state.requiresReauthentication)
    }

    @Test func generationInvalidationDiscardsOlderRecoveryState() {
        let recovery = AppSessionRecovery()
        let identity = recovery.identity
        recovery.noteFailure(KeychainReadError.unavailable(errSecAuthFailed), hasOpenBudget: false)
        #expect(recovery.state == .blocked(.unavailable(errSecAuthFailed)))
        recovery.invalidate()
        #expect(!recovery.isCurrent(identity))
        #expect(recovery.state == .idle)
    }
}
