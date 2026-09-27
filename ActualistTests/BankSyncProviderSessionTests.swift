import Foundation
import Testing
@testable import Actualist

@MainActor
struct BankSyncProviderSessionTests {
    private actor Provider: SimpleFINServerTransport {
        let pauseAccounts: Bool
        let entered: TestLatch
        let release: TestLatch
        private(set) var didEnter = false

        init(pauseAccounts: Bool, entered: TestLatch, release: TestLatch) {
            self.pauseAccounts = pauseAccounts
            self.entered = entered
            self.release = release
        }

        private func pause() async {
            didEnter = true
            entered.trip()
            // Deliberately ignores cancellation, representing a late provider response.
            await release.wait()
        }

        func simpleFINStatus(token: String) async throws -> SimpleFINServerSupport {
            if !pauseAccounts { await pause() }
            return .configured
        }

        func simpleFINAccounts(token: String) async throws -> [SimpleFINRemoteAccount]? {
            if pauseAccounts { await pause() }
            return []
        }

        func simpleFINTransactions(token: String, accountIDs: [String], startDates: [String]) async throws -> SimpleFINTransactionsResponse? {
            .init(downloads: [:], errorType: nil, errorCode: nil)
        }
    }

    @Test(arguments: ["support", "provider", "accounts"])
    func lateProviderMetadataCannotPopulateReplacementSession(operation: String) async throws {
        let entered = TestLatch()
        let release = TestLatch()
        let provider = Provider(pauseAccounts: operation == "accounts", entered: entered, release: release)
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle(simpleFINTransportFactory: { _ in provider })
        bundle.store.openedServerURLString = "https://original.example"
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let task = Task {
            switch operation {
            case "support": _ = try await bundle.store.bankSyncSupport(budgetID: "group-1")
            case "provider": _ = try await bundle.store.bankSyncProvider(budgetID: "group-1")
            default: _ = try await bundle.store.bankSyncRemoteAccounts(budgetID: "group-1")
            }
        }
        // Release both waits if entry fails, even if framework cancellation alone
        // cannot terminate the deliberately cancellation-insensitive fake.
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            entered.trip()
            release.trip()
        }
        defer { deadline.cancel(); task.cancel(); release.trip() }
        await entered.wait()
        try #require(await provider.didEnter)
        bundle.store.reset()
        bundle.store.openedServerURLString = "https://replacement.example"
        release.trip()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(bundle.store.cachedBankSyncSupport() == nil)
        #expect(bundle.store.cachedBankSyncRemoteAccounts() == nil)
    }
}
