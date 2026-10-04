import Foundation

struct LocalFirstSyncStatus: Equatable, Sendable {
    var fileID: String
    var groupID: String?
    var lastSyncedAt: Date?
    var lastAppliedMessageCount: Int
    var lastUploadedMessageCount: Int
    var lastSyncAttemptAt: Date?
    var lastError: String?
    var encryptionKeyID: String?
    var pendingLocalMessageCount: Int
    /// `true` when the most recent successful sync reached the server through
    /// the fallback endpoint. Reflects the last successful sync only; failed
    /// attempts do not change it.
    var lastSyncUsedFallback: Bool = false

    init(
        fileID: String,
        groupID: String?,
        lastSyncedAt: Date? = nil,
        lastAppliedMessageCount: Int = 0,
        lastUploadedMessageCount: Int = 0,
        lastSyncAttemptAt: Date? = nil,
        lastError: String? = nil,
        encryptionKeyID: String? = nil,
        pendingLocalMessageCount: Int = 0,
        lastSyncUsedFallback: Bool = false
    ) {
        self.fileID = fileID
        self.groupID = groupID
        self.lastSyncedAt = lastSyncedAt
        self.lastAppliedMessageCount = lastAppliedMessageCount
        self.lastUploadedMessageCount = lastUploadedMessageCount
        self.lastSyncAttemptAt = lastSyncAttemptAt
        self.lastError = lastError
        self.encryptionKeyID = encryptionKeyID
        self.pendingLocalMessageCount = pendingLocalMessageCount
        self.lastSyncUsedFallback = lastSyncUsedFallback
    }
}

struct LocalFirstBudgetMetadata: Codable, Equatable, Sendable {
    let localBudgetID: String
    let cloudFileID: String
    let groupID: String?
    let budgetName: String
    let encryptionKeyID: String?
    let nodeID: String

    enum CodingKeys: String, CodingKey {
        case localBudgetID, budgetName, encryptionKeyID, nodeID
        case cloudFileID = "cloudFileId"
        case groupID = "groupId"
    }
}

