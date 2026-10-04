import Foundation
import Testing
@testable import Actualist

/// Phase 3.1: the primary and fallback server URLs share one rule, and a bad
/// fallback is rejected at save, ignored at hydration, and redacted from reports.
@MainActor
struct ServerURLSecurityHardeningTests {
    private static let rejectedInputs = [
        "http://public.example.com",
        "ftp://fallback.example.com",
        "https://user:secret@fallback.example.com",
        "https://user@fallback.example.com"
    ]
    private static let acceptedInputs = [
        "https://public.example.com",
        "actual.example.com",
        "http://192.168.1.16:5007",
        "http://nas.local:5006",
        "http://actual.tailnet-name.ts.net:5006",
        "https://actual.tailnet-name.ts.net"
    ]

    @Test func rejectionAppliesTheSameRuleToAnyServerURL() {
        for input in Self.rejectedInputs {
            #expect(ActualServerConnectionSecurity.rejection(for: input) != nil, "\(input)")
        }
        for input in Self.acceptedInputs {
            #expect(ActualServerConnectionSecurity.rejection(for: input) == nil, "\(input)")
        }
        #expect(ActualServerConnectionSecurity.rejection(for: "") == nil)
    }

    @Test func failoverEndpointsIgnoreARejectedFallbackButKeepLocalOnes() {
        let store = LocalFirstActualStore()
        for input in Self.rejectedInputs {
            store.fallbackServerURLString = input
            let endpoints = store.failoverEndpoints(for: "https://primary.example.com")
            #expect(endpoints.primary?.absoluteString == "https://primary.example.com")
            #expect(endpoints.fallback == nil, "\(input)")
        }
        for input in ["http://192.168.1.16:5007", "http://actual.tailnet-name.ts.net:5006"] {
            store.fallbackServerURLString = input
            #expect(store.failoverEndpoints(for: "https://primary.example.com").fallback != nil, "\(input)")
        }
    }

    @Test func savingARejectedFallbackReturnsAMessageAndChangesNothing() {
        let state = makeAppState()
        #expect(state.updateFallbackServerURL("https://good.example.com") == nil)
        for input in Self.rejectedInputs {
            let message = state.updateFallbackServerURL(input)
            #expect(message != nil, "\(input)")
            #expect(state.settings.fallbackServerURLString == "https://good.example.com", "\(input)")
            #expect(state.localFirstStore.fallbackServerURLString == "https://good.example.com", "\(input)")
        }
        #expect(state.updateFallbackServerURL("http://192.168.1.16:5007") == nil)
        #expect(state.settings.fallbackServerURLString == "http://192.168.1.16:5007")
        #expect(state.updateFallbackServerURL("") == nil)
        #expect(state.settings.fallbackServerURLString.isEmpty)
        #expect(state.localFirstStore.fallbackServerURLString == nil)
    }

    @Test func aStoredRejectedFallbackIsIgnoredAtHydration() throws {
        let defaults = try #require(UserDefaults(suiteName: "ServerURLSecurityHardeningTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        var settings = settingsStore.load()
        settings.fallbackServerURLString = "http://public.example.com"
        settingsStore.save(settings)
        let state = AppState(
            settingsStore: settingsStore,
            keychain: KeychainStore(service: "com.sporez.actualist.tests", account: UUID().uuidString),
            localFirstStore: LocalFirstActualStore()
        )
        #expect(state.localFirstStore.fallbackServerURLString == nil)
    }

    @Test func aPrimaryWithEmbeddedCredentialsOrAnUnsupportedSchemeIsRejected() async {
        let store = LocalFirstActualStore(connectionTransportFactory: { _ in StubConnectionTransport() })
        let state = AppState(
            settingsStore: AppSettingsStore(
                defaults: UserDefaults(suiteName: "ServerURLSecurityHardeningTests.\(UUID().uuidString)")!
            ),
            keychain: KeychainStore(service: "com.sporez.actualist.tests", account: UUID().uuidString),
            localFirstStore: store
        )
        for input in ["https://user:secret@actual.example.com", "ftp://actual.example.com"] {
            state.lastErrorMessage = nil
            let response = await state.loadLocalFirstLoginMethods(serverURLString: input)
            #expect(response == nil, "\(input)")
            #expect(state.lastErrorMessage == ActualServerConnectionSecurity.rejection(for: input), "\(input)")
            #expect(state.lastErrorMessage != nil, "\(input)")
        }
    }

    @Test func reportContainsNeitherTheFallbackURLNorItsHost() {
        let state = makeAppState()
        state.settings.localFirstServerURLString = "https://primary.private.example"
        state.settings.fallbackServerURLString = "https://fallback.private.example:5006"
        state.localFirstStore.fallbackServerURLString = "https://fallback.private.example:5006"
        state.lastErrorMessage = "Could not reach fallback.private.example and primary.private.example"
        let report = ActualistDiagnosticReportBuilder.make(appState: state).text
        for secret in ["fallback.private.example", "primary.private.example", "5006"] {
            #expect(!report.contains(secret), "\(secret)")
        }
    }

    @Test func redactionInputsIncludeBothServerHosts() {
        let state = makeAppState()
        state.settings.localFirstServerURLString = "https://primary.private.example"
        state.settings.fallbackServerURLString = "https://fallback.private.example:5006"
        let values = ActualistDiagnosticReportBuilder.sensitiveValues(appState: state)
        for expected in [
            "primary.private.example", "fallback.private.example",
            "https://fallback.private.example:5006"
        ] {
            #expect(values.contains(expected), "\(expected)")
        }
    }

    private func makeAppState() -> AppState {
        AppState(
            settingsStore: AppSettingsStore(
                defaults: UserDefaults(suiteName: "ServerURLSecurityHardeningTests.\(UUID().uuidString)")!
            ),
            keychain: KeychainStore(service: "com.sporez.actualist.tests", account: UUID().uuidString),
            localFirstStore: LocalFirstActualStore()
        )
    }
}
