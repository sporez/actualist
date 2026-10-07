import Foundation
import Testing
@testable import Actualist

/// Concurrency 5.5c (audit CA-19): the picker's open uses an idle timeout, a
/// cancelled caller cancels the download, and a cancelled switch puts the
/// previous budget back.
@MainActor
struct BudgetOpenIdleTimeoutTests {
    private let fixtures = LocalFirstActualStoreTests()
    private static let timeoutMessage =
        "Opening this budget is taking too long. Check your connection to the Actual server and try again."

    private func target() -> (budget: ActualBudget, remote: ActualSyncRemoteFile) {
        (
            ActualBudget(budgetID: "file-2", cloudFileId: "file-2", groupId: "group-2", name: "Budget 2", state: nil),
            ActualSyncRemoteFile(fileID: "file-2", groupID: "group-2", name: "Budget 2")
        )
    }

    private func readyState(
        server: StubConnectionTransport, remote: ActualSyncRemoteFile
    ) async throws -> (AppState, LocalFirstActualStoreTests.OpenedWritableStoreBundle) {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in server }
        )
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try fixtures.makeAppState(for: bundle)
        appState.selectedBudget = bundle.budget
        appState.setupPhase = .ready
        appState.connectionStatus = .online
        return (appState, bundle)
    }

    @Test func aStalledOpenIsCancelledAfterTheIdleWindowAndReportsTheTimeout() async throws {
        let (budget, remote) = target()
        let server = StubConnectionTransport(files: [remote], downloadDelay: .seconds(30))
        let (appState, _) = try await readyState(server: server, remote: remote)
        let picker = BudgetPickerViewModel(openIdleTimeout: .milliseconds(300))

        picker.selectBudget(budget, using: appState)
        await picker.openTask?.value

        #expect(picker.openState == .failed(message: Self.timeoutMessage))
        let cancelled = await server.downloadCancelled.wait(timeout: .seconds(10))
        #expect(cancelled)
    }

    @Test func aSlowOpenThatKeepsMakingProgressIsNotTimedOut() async throws {
        let (budget, remote) = target()
        // 1.2 s in total, but a tick every 200 ms: never idle for the 600 ms window.
        let server = StubConnectionTransport(
            files: [remote], downloadDelay: .milliseconds(1_200), downloadProgressTicks: 6
        )
        let (appState, _) = try await readyState(server: server, remote: remote)
        let picker = BudgetPickerViewModel(openIdleTimeout: .milliseconds(600))

        picker.selectBudget(budget, using: appState)
        await picker.openTask?.value

        #expect(picker.openState != .failed(message: Self.timeoutMessage))
    }

    @Test func aReplacedOpenCancelsTheDownloadOfTheOneItReplaced() async throws {
        let (budget, remote) = target()
        let server = StubConnectionTransport(files: [remote], downloadDelay: .seconds(30))
        let (appState, _) = try await readyState(server: server, remote: remote)
        let picker = BudgetPickerViewModel(openIdleTimeout: .seconds(120))

        picker.selectBudget(budget, using: appState)
        let started = await server.downloadStarted.wait(timeout: .seconds(20))
        #expect(started)
        // A newer open replaces the first; the first one's download must stop.
        picker.selectBudget(budget, using: appState)

        let cancelled = await server.downloadCancelled.wait(timeout: .seconds(10))
        #expect(cancelled, "the replaced open kept downloading")
        picker.openTask?.cancel()
        appState.budgetSessionTransitions.cancel()
    }

    @Test func aCancelledSwitchRestoresThePreviousBudget() async throws {
        let (budget, remote) = target()
        let server = StubConnectionTransport(files: [remote], downloadDelay: .seconds(30))
        let (appState, bundle) = try await readyState(server: server, remote: remote)
        #expect(bundle.store.isOpen(budgetID: "group-1"))

        let select = Task { await appState.selectBudgetForCurrentBackend(budget) }
        let started = await server.downloadStarted.wait(timeout: .seconds(20))
        #expect(started)
        #expect(!bundle.store.hasOpenBudget)
        // What the picker's watchdog does when the open stalls.
        appState.budgetSessionTransitions.cancel()
        _ = await select.value

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(appState.setupPhase == .ready)
        #expect(appState.selectedBudget?.syncID == "group-1")
    }
}
