import Foundation
import Testing
@testable import Actualist

/// Concurrency remediation 4.4: launch-snapshot revision reads, snapshot reads
/// and snapshot writes must not touch the disk on the main thread. DEBUG builds
/// log main-thread calls into `MainThreadCallLog`, keyed by the sidecar path
/// under the test's own store root.
@MainActor
@Suite("Launch snapshot off main")
struct BudgetLaunchSnapshotOffMainTests {
    private let support = LocalFirstActualStoreTests()

    @Test func launchSeedAndBudgetReadsTouchTheSidecarOffTheMainThread() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        // Positive control: the open wrote a snapshot, so the write stage ran.
        #expect(FileManager.default.fileExists(atPath: files.snapshotURL.path))

        _ = try await bundle.store.readBudgetMonth(budgetID: "group-1", month: "2026-07")

        let root = bundle.fileManager.applicationSupportURL.lastPathComponent
        for stage in ["launchSnapshotPrepare", "launchSnapshotRead", "launchSnapshotWrite"] {
            #expect(
                MainThreadCallLog.mainThreadCalls(stage: stage, keyContaining: root).isEmpty,
                "\(stage) ran on the main thread"
            )
        }
    }
}
