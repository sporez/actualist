import Foundation
import Testing
@testable import Actualist

@MainActor
struct OnboardingStaleLoginMethodsTests {
    @Test func loginMethodsForAnEditedURLAreDiscardedAndOpenIDNeverStarts() async throws {
        let transport = StubConnectionTransport()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests", account: UUID().uuidString,
            backend: FakeKeychainBackend()
        )
        let store = LocalFirstActualStore(keychain: keychain, connectionTransportFactory: { _ in transport })
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let appState = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: keychain,
            localFirstStore: store
        )
        let openIDOnly = try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self, from: Data(#"{"methods":["openid"]}"#.utf8)
        )
        let entered = TestLatch()
        let release = TestLatch()
        let model = OnboardingViewModel(loginMethodsLoader: { _, _ in
            entered.trip()
            await release.wait()
            return openIDOnly
        })
        model.serverURLString = "https://a.example"

        let task = Task {
            await model.continueFromServer(using: appState) { _ in
                Issue.record("A stale response must not start OpenID")
                throw CancellationError()
            }
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            entered.trip()
            release.trip()
        }
        defer { deadline.cancel(); task.cancel(); release.trip() }
        await entered.wait()
        model.serverURLString = "https://b.example"
        release.trip()
        await task.value

        #expect(model.loginMethods.isEmpty)
        #expect(!model.hasLoadedLoginMethods)
        #expect(!model.isLoadingLoginMethods)
        #expect(!model.isConnecting)
        #expect(await transport.capturedOpenIDReturnURL == nil)
    }
}
