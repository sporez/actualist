import Foundation
import Security
import Testing
@testable import Actualist

extension CustomHTTPHeaderTransportTests {
    @Test @MainActor func draftsPreserveSavedValuesRequireReviewAndRejectConcurrentReplacement() throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: backend)
        let store = LocalFirstActualStore(keychain: keychain)
        let saved = try configuration()
        try store.saveCustomHTTPHeaders(saved)
        let model = CustomHeadersSettingsViewModel(store: store, primaryURLString: "https://changed.example", fallbackURLString: "https://fallback.example")
        #expect(model.endpoints[0].needsOriginReview)
        #expect(!model.save())
        #expect(try keychain.readCustomHTTPHeaders() == saved)
        model.reviewOrigin(for: .primary)
        model.updateHeader(model.endpoints[0].headers[0].id, role: .primary, value: "changed-secret")
        #expect(try keychain.readCustomHTTPHeaders() == saved)
        #expect(model.save())
        #expect(try keychain.readCustomHTTPHeaders().primary?.origin.host == "changed.example")
        #expect(try keychain.readCustomHTTPHeaders().fallback == saved.fallback)
        let obsolete = CustomHeadersSettingsViewModel(store: store, primaryURLString: "https://changed.example", fallbackURLString: "https://fallback.example")
        try store.saveCustomHTTPHeaders(.init())
        #expect(!obsolete.save())
        #expect(try keychain.readCustomHTTPHeaders() == .init())
        let removal = CustomHeadersSettingsViewModel(store: store, primaryURLString: "https://changed.example", fallbackURLString: "")
        removal.addHeader(to: .primary)
        #expect(!removal.save())
        removal.removeHeaders(at: IndexSet(integer: 0), role: .primary)
        #expect(removal.save())
        backend.copyFailureStatus = errSecInteractionNotAllowed
        let locked = CustomHeadersSettingsViewModel(store: store, primaryURLString: "https://primary.example", fallbackURLString: "")
        #expect(!locked.canSave)
        #expect(locked.errorMessage != nil)
    }

    @Test @MainActor func draftTestingAndCancellationNeverPersistOrPublishStaleResults() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        let store = LocalFirstActualStore(keychain: keychain)
        try store.saveCustomHTTPHeaders(configuration())
        let model = CustomHeadersSettingsViewModel(store: store, primaryURLString: "https://primary.example", fallbackURLString: "", verifier: .init(session: session))
        let id = model.endpoints[0].headers[0].id
        model.updateHeader(id, role: .primary, value: "draft-secret")
        model.testConnection(for: .primary)
        for _ in 0..<200 {
            if !model.isTesting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.phase == .result(.primary, .init(requiresHeaders: false)))
        #expect(HeaderTransportURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Primary") == "draft-secret")
        #expect(try keychain.readCustomHTTPHeaders().primary?.headers[0].value == "primary-secret")
        let obsolete = model.testConnection(for: .primary)
        model.updateHeader(id, role: .primary, value: "newer-draft")
        await obsolete?.value
        #expect(model.phase == .editing)
        let cancelled = model.testConnection(for: .primary)
        model.cancelTesting()
        await cancelled?.value
        #expect(model.phase == .editing)
    }

    @Test @MainActor func summaryExcludesStaleOriginsAndPreservesConnectionDraftOnReturn() throws {
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        let store = LocalFirstActualStore(keychain: keychain)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults), keychain: keychain, localFirstStore: store)
        state.settings.localFirstServerURLString = "https://primary.example"
        state.settings.fallbackServerURLString = "https://fallback.example"
        let model = SettingsViewModel()
        model.hydrateConnectionIfNeeded(from: state)
        try store.saveCustomHTTPHeaders(configuration())
        #expect(model.customHeadersSummary(using: store) == "2 Configured")
        model.serverURLString = "https://changed.example"
        model.hydrateConnectionIfNeeded(from: state)
        #expect(model.serverURLString == "https://changed.example")
        #expect(model.customHeadersSummary(using: store) == "1 Configured")
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains("primary-secret"))
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains("fallback-secret"))
        state.lastErrorMessage = "X-Primary primary-secret X-Fallback fallback-secret"
        let report = ActualistDiagnosticReportBuilder.make(appState: state).text
        #expect(!report.contains("primary-secret"))
        #expect(!report.contains("fallback-secret"))
        #expect(!report.contains("X-Primary"))
        #expect(!report.contains("X-Fallback"))
    }

    @Test func oidcInitialBrowserHeadersAreBoundToActualOrigin() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://primary.example")!
        let client = ActualServerSyncClient(baseURL: url, customHeaders: try configuration().fields(for: .primary, url: url), session: session)
        for crossOrigin in [false, true] {
            HeaderTransportURLProtocol.mode = crossOrigin ? .crossOriginOIDC : .normal
            let token = try await ActualOpenIDAuthenticationCoordinator().authenticate(client: client) { request in
                #expect(request.additionalHeaderFields["X-Primary"] == (crossOrigin ? nil : "primary-secret"))
                var callback = try #require(HeaderTransportURLProtocol.callbackURL)
                callback.append(path: "openid-cb")
                callback.append(queryItems: [.init(name: "token", value: "actual-token")])
                return callback
            }
            #expect(token == "actual-token")
        }
    }
}
