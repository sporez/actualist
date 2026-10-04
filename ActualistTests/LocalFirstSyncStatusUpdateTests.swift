import Foundation
import Testing
@testable import Actualist

@Suite("Sync status merging")
struct LocalFirstSyncStatusUpdateTests {
    private func current() -> LocalFirstSyncStatus {
        LocalFirstSyncStatus(
            fileID: "file-1",
            groupID: "group-1",
            lastSyncedAt: Date(timeIntervalSince1970: 100),
            lastAppliedMessageCount: 4,
            lastUploadedMessageCount: 9,
            lastSyncAttemptAt: Date(timeIntervalSince1970: 500),
            lastError: "earlier failure",
            encryptionKeyID: "key",
            pendingLocalMessageCount: 7
        )
    }

    private func update(
        pending: Int? = nil,
        success: LocalFirstSyncStatusUpdate.Success? = nil,
        error: String? = nil
    ) -> LocalFirstSyncStatusUpdate {
        LocalFirstSyncStatusUpdate(
            fileID: "file-1", groupID: "group-1", encryptionKeyID: "key",
            pendingLocalMessageCount: pending, success: success, errorDescription: error
        )
    }

    @Test func pendingCountOnlyUpdateKeepsFieldsAnotherCallChangedMeanwhile() {
        let merged = current().merging(update(pending: 2))

        #expect(merged.pendingLocalMessageCount == 2)
        #expect(merged.lastSyncAttemptAt == Date(timeIntervalSince1970: 500))
        #expect(merged.lastError == "earlier failure")
        #expect(merged.lastAppliedMessageCount == 4)
        #expect(merged.lastUploadedMessageCount == 9)
    }

    @Test func unreadPendingCountKeepsTheCurrentCount() {
        #expect(current().merging(update(pending: nil)).pendingLocalMessageCount == 7)
    }

    @Test func successClearsErrorAndKeepsUploadCountWhenNothingUploaded() {
        let success = LocalFirstSyncStatusUpdate.Success(
            lastSyncedAt: Date(timeIntervalSince1970: 900), appliedCount: 3, uploadedCount: 0, usedFallback: true
        )
        let merged = current().merging(update(pending: 0, success: success))

        #expect(merged.lastSyncedAt == Date(timeIntervalSince1970: 900))
        #expect(merged.lastAppliedMessageCount == 3)
        #expect(merged.lastUploadedMessageCount == 9)
        #expect(merged.lastError == nil)
        #expect(merged.lastSyncUsedFallback)
        #expect(merged.lastSyncAttemptAt == Date(timeIntervalSince1970: 500))
    }

    @Test func errorUpdateSetsLastErrorAndLeavesSuccessFieldsAlone() {
        let merged = current().merging(update(error: "boom"))

        #expect(merged.lastError == "boom")
        #expect(merged.lastSyncedAt == Date(timeIntervalSince1970: 100))
        #expect(merged.lastUploadedMessageCount == 9)
    }
}
