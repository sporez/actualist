import Foundation

/// The result of one `recordSyncStatus` call, gathered across awaits and merged
/// into the *current* status in one synchronous step. Merging into a copy read
/// before the awaits would overwrite fields another call changed meanwhile
/// (for example `lastSyncAttemptAt`).
struct LocalFirstSyncStatusUpdate: Equatable, Sendable {
    struct Success: Equatable, Sendable {
        let lastSyncedAt: Date
        let appliedCount: Int
        let uploadedCount: Int
        let usedFallback: Bool
    }

    let fileID: String
    let groupID: String?
    let encryptionKeyID: String?
    /// `nil` keeps the current count (unread, or a newer read already landed).
    var pendingLocalMessageCount: Int?
    var success: Success?
    /// Applied only when `success` is nil.
    var errorDescription: String?
}

extension LocalFirstSyncStatus {
    func merging(_ update: LocalFirstSyncStatusUpdate) -> LocalFirstSyncStatus {
        var status = self
        status.fileID = update.fileID
        status.groupID = update.groupID
        status.encryptionKeyID = update.encryptionKeyID
        if let count = update.pendingLocalMessageCount {
            status.pendingLocalMessageCount = count
        }
        if let success = update.success {
            status.lastSyncedAt = success.lastSyncedAt
            status.lastAppliedMessageCount = success.appliedCount
            if success.uploadedCount > 0 {
                status.lastUploadedMessageCount = success.uploadedCount
            }
            status.lastError = nil
            status.lastSyncUsedFallback = success.usedFallback
        } else if let errorDescription = update.errorDescription {
            status.lastError = errorDescription
        }
        return status
    }
}
