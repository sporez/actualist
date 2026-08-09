import Foundation
import Testing
@testable import Actualist

@MainActor
struct DiagnosticReportTests {
    @Test func redactorRemovesKnownAndCommonSensitiveValues() {
        let redactor = DiagnosticReportRedactor(
            sensitiveValues: ["My Family Budget", "account-secret-id", "actual.private.example"]
        )

        let result = redactor.redact(
            "My Family Budget failed for account-secret-id at https://actual.private.example/sync "
                + "from 192.168.1.7 user@example.com token=topsecret "
                + "file /Users/person/Budgets/db.sqlite amount $4,294.87\nretrying"
        )

        #expect(!result.contains("My Family Budget"))
        #expect(!result.contains("account-secret-id"))
        #expect(!result.contains("actual.private.example"))
        #expect(!result.contains("192.168.1.7"))
        #expect(!result.contains("user@example.com"))
        #expect(!result.contains("topsecret"))
        #expect(!result.contains("/Users/person"))
        #expect(!result.contains("4,294.87"))
        #expect(!result.contains("\n"))
    }

    @Test func reportIncludesComprehensiveStateWithoutUserData() throws {
        let state = makeAppState()
        state.setupPhase = .ready
        state.connectionStatus = .offline
        state.settings.localFirstServerURLString = "https://actual.private.example"
        state.settings.selectedBudgetID = "private-budget-id"
        state.settings.selectedBudgetName = "My Family Budget"
        state.settings.selectedLocalFirstFileID = "private-file-id"
        state.settings.selectedLocalFirstGroupID = "private-group-id"
        state.settings.backgroundTransactionRefreshEnabled = true
        state.settings.enabledExperimentalFeatures = [.budgetTemplates]
        state.settings.pendingNewTransactionIDsByAccount = [
            "private-budget-id|private-account-id": ["transaction-one", "transaction-two"]
        ]
        state.settings.localFirstSyncDebug = LocalFirstSyncDebugInfo(
            totalEventCount: 12,
            recentEvents: [
                LocalFirstSyncDebugEvent(
                    id: UUID(),
                    date: Date(timeIntervalSince1970: 1_700_000_000),
                    outcome: .failed,
                    pendingBefore: 3,
                    uploadedCount: 0,
                    downloadedCount: 0,
                    pendingAfter: 3,
                    message: "My Checking failed at https://actual.private.example/sync"
                )
            ]
        )
        state.settings.backgroundRefreshDebug = BackgroundRefreshDebugInfo(
            totalWakeCount: 4,
            recentRuns: [
                BackgroundRefreshDebugRun(
                    id: UUID(),
                    wakeDate: Date(timeIntervalSince1970: 1_700_000_100),
                    completionDate: Date(timeIntervalSince1970: 1_700_000_101),
                    succeeded: false,
                    message: "My Checking failed for private-account-id"
                )
            ],
            totalScheduleAttemptCount: 5,
            recentScheduleAttempts: []
        )
        state.lastErrorMessage = "Could not reach actual.private.example for private-budget-id"
        state.budgets = [
            ActualBudget(
                budgetID: "private-file-id",
                cloudFileId: "private-file-id",
                groupId: "private-group-id",
                name: "My Family Budget",
                state: nil
            )
        ]
        state.selectedBudget = state.budgets[0]

        let store = state.localFirstStore
        store.openedBudgetID = "private-budget-id"
        store.openedGroupID = "private-group-id"
        store.openedNodeID = "private-node-id"
        store.openedServerURLString = "https://actual.private.example"
        store.cachedBudgets = state.budgets
        store.accountsByBudget = [
            "private-budget-id": [
                AccountDisplay(
                    account: ActualAccount(
                        id: "private-account-id",
                        name: "My Checking",
                        offbudget: false,
                        closed: false
                    ),
                    balance: 429_487
                )
            ]
        ]
        store.syncStatus = LocalFirstSyncStatus(
            fileID: "private-file-id",
            groupID: "private-group-id",
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAppliedMessageCount: 8,
            lastUploadedMessageCount: 2,
            lastSyncAttemptAt: Date(timeIntervalSince1970: 1_700_000_010),
            lastError: "My Checking failed at https://actual.private.example",
            encryptionKeyID: "private-encryption-id",
            pendingLocalMessageCount: 3
        )

        let report = ActualistDiagnosticReportBuilder.make(
            appState: state,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            reportID: try #require(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        )

        #expect(report.filename == "Actualist-Diagnostics-20231114-221640Z.txt")
        #expect(report.text.contains("Actualist Diagnostic Report"))
        #expect(report.text.contains("Setup phase: ready"))
        #expect(report.text.contains("Connection status: offline"))
        #expect(report.text.contains("Experimental features enabled: budgetTemplates"))
        #expect(report.text.contains("Pending local messages: 3"))
        #expect(report.text.contains("Total recorded events: 12"))
        #expect(report.text.contains("Total schedule attempts: 5"))
        #expect(report.text.contains("Total wakes: 4"))
        #expect(report.text.contains("Transaction count: 2"))
        #expect(!report.text.contains("actual.private.example"))
        #expect(!report.text.contains("private-budget-id"))
        #expect(!report.text.contains("private-file-id"))
        #expect(!report.text.contains("private-group-id"))
        #expect(!report.text.contains("private-node-id"))
        #expect(!report.text.contains("private-account-id"))
        #expect(!report.text.contains("private-encryption-id"))
        #expect(!report.text.contains("My Family Budget"))
        #expect(!report.text.contains("My Checking"))
        #expect(!report.text.contains("429487"))
    }

    private func makeAppState() -> AppState {
        let defaults = UserDefaults(suiteName: "ActualistDiagnosticReportTests.\(UUID().uuidString)")!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.diagnostic-tests",
                account: UUID().uuidString
            )
        )
    }
}

struct ActualServerErrorRedactionTests {
    @Test func decodingErrorDoesNotExposeResponseOrServerURL() async throws {
        let client = makeClient(host: "invalid.actual.private.example")

        do {
            _ = try await client.loginMethods()
            Issue.record("Expected invalid JSON to fail decoding")
        } catch {
            let message = error.localizedDescription
            #expect(message == "Actualist could not read the server response.")
            #expect(!message.contains("private-token"))
            #expect(!message.contains("123456789"))
            #expect(!message.contains("actual.private.example"))
        }
    }

    @Test func HTTPErrorDoesNotExposeResponseOrServerURL() async throws {
        let client = makeClient(host: "denied.actual.private.example")

        do {
            _ = try await client.loginMethods()
            Issue.record("Expected the HTTP response to fail")
        } catch {
            let message = error.localizedDescription
            #expect(message == "Your Actual session is no longer valid. Sign in again to resume syncing.")
            #expect(!message.contains("private-token"))
            #expect(!message.contains("123456789"))
            #expect(!message.contains("actual.private.example"))
        }
    }

    @Test func transportErrorDoesNotExposeFailingURL() async throws {
        let client = makeClient(host: "offline.actual.private.example")

        do {
            _ = try await client.loginMethods()
            Issue.record("Expected the transport to fail")
        } catch {
            let message = error.localizedDescription
            #expect(message == "Actualist could not reach the server.")
            #expect(!message.contains("offline.actual.private.example"))
            #expect(!message.contains("private-token"))
        }
    }

    private func makeClient(host: String) -> ActualServerSyncClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SensitiveResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return ActualServerSyncClient(
            baseURL: URL(string: "https://\(host)/base?token=private-token")!,
            session: session
        )
    }
}

private final class SensitiveResponseURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch url.host {
        case "invalid.actual.private.example":
            send(
                statusCode: 200,
                body: #"{not-json "token":"private-token","accountNumber":"123456789"}"#
            )
        case "denied.actual.private.example":
            send(
                statusCode: 401,
                body: #"private-token account 123456789 at https://actual.private.example"#
            )
        default:
            client?.urlProtocol(
                self,
                didFailWithError: URLError(
                    .cannotConnectToHost,
                    userInfo: [
                        NSURLErrorFailingURLErrorKey: url,
                        NSURLErrorFailingURLStringErrorKey: url.absoluteString
                    ]
                )
            )
        }
    }

    override func stopLoading() {}

    private func send(statusCode: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
