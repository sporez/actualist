import Foundation

enum LocalFirstRecoveryGuidance {
    static let encryptionPasswordNotice = """
        This encryption password cannot be recovered by Actualist. Store it securely somewhere \
        you can access if this iPhone is lost or replaced. Actualist stores only the unlocked \
        budget key on this device, not the password. Neither is included in device backups.
        """
}

enum LocalFirstError: LocalizedError, Equatable {
    case missingServerURL
    case missingPassword
    case missingSyncToken
    case missingBudgetFileID
    case noBudgetsAvailable
    case selectedBudgetUnavailable
    case invalidBudgetFileID
    case numericValueOutOfRange
    case unsupportedWrite
    case unsupportedTransferWrite
    case unsupportedSplitWrite
    case encryptedBudgetRequiresPassword
    case invalidEncryptionPassword
    case invalidEncryptionKey
    case invalidEncryptedPayload
    /// The server refused sync because this budget's remote encryption
    /// identity (key ID) no longer matches the one Actualist opened with.
    case budgetEncryptionChanged
    case unsupportedEncryptionAlgorithm(String)
    case missingImportedDatabase
    case invalidDownloadedBudget
    case localBudgetHardeningFailed
    /// A reimport failed and the previous local copy could not be put back;
    /// the copy is kept and restored the next time the budget opens.
    case reimportRollbackFailed
    case remoteDataLimitExceeded
    case insufficientStorage
    case invalidLocalWrite(String)
    /// A History undo was refused by the conflict check; the string is the
    /// user-facing reason (from `BudgetActionUndoBlock.userFacingReason`).
    case actionUndoBlocked(String)
    case budgetNotOpened
    case unsupportedTemplate(String)
    case budgetTemplateReviewStale
    case budgetHoldReviewStale
    case keychainFailure(String, OSStatus)
    case hybridLogicalClockOverflow
    case localWriteSuperseded
    /// An import's `imported_id` already exists on the account, so applying it would duplicate the transaction.
    case importedTransactionConflict
    case syncUploadNotConfirmed(Int)
    case unauthenticatedPlaintextEnvelope
    /// A remote or stored timestamp is more than five minutes ahead of this device.
    case clockDrift
    /// A remote message carries a timestamp that is not a valid Actual timestamp.
    case invalidSyncTimestamp
    /// A server message could not be decrypted or parsed. Fatal, as upstream.
    case undecryptableMessage
    /// A decrypted message carries a value Actualist cannot read. Quarantined, never fatal.
    case invalidSyncValue
    /// The merkle re-pull loop could not bring this file and the server into agreement.
    case syncOutOfSync

    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            "Enter an Actual server URL."
        case .missingPassword:
            "Enter your Actual server password."
        case .missingSyncToken:
            "Sign in to the Actual server before loading budgets."
        case .missingBudgetFileID:
            "The selected Actual budget does not include a file ID."
        case .noBudgetsAvailable:
            "This Actual server has no budgets available."
        case .selectedBudgetUnavailable:
            "The selected budget is not available on this Actual server."
        case .invalidBudgetFileID:
            "The Actual budget file ID is not safe to use."
        case .numericValueOutOfRange:
            "Actualist found a numeric value outside the supported range."
        case .unsupportedWrite:
            "This local-first write is not available yet."
        case .unsupportedTransferWrite:
            "This transfer write is not available."
        case .unsupportedSplitWrite:
            "This split transaction write is not available."
        case .encryptedBudgetRequiresPassword:
            "This encrypted budget needs an encryption password before Actualist can open it."
        case .invalidEncryptionPassword:
            "The encryption password could not unlock this budget."
        case .invalidEncryptionKey:
            "Actualist could not load this budget's encryption key."
        case .invalidEncryptedPayload:
            "Actualist could not read encrypted budget data from the server."
        case .budgetEncryptionChanged:
            "This budget's encryption settings changed on the server. Re-open the budget and enter its current encryption password."
        case .unsupportedEncryptionAlgorithm(let algorithm):
            "Actualist does not support this budget encryption algorithm: \(algorithm)."
        case .missingImportedDatabase:
            "Actualist could not find db.sqlite in the imported budget."
        case .invalidDownloadedBudget:
            "The downloaded budget file could not be imported."
        case .localBudgetHardeningFailed:
            "Actualist could not secure the local budget files."
        case .reimportRollbackFailed:
            "Actualist could not restore your previous budget copy after the reimport failed. Your previous copy is kept on this device. Try again."
        case .remoteDataLimitExceeded:
            "The server response exceeded Actualist's safe resource limits."
        case .insufficientStorage:
            "This device does not have enough free storage to import the budget safely."
        case .invalidLocalWrite(let reason):
            "Actualist could not apply the local-first write: \(reason)"
        case .actionUndoBlocked(let reason):
            reason
        case .budgetNotOpened:
            "Open a local-first budget before loading this screen."
        case .unsupportedTemplate(let reason):
            "This budget template can't be applied locally yet: \(reason)"
        case .budgetTemplateReviewStale:
            "This template preview is out of date. Review it again before applying."
        case .budgetHoldReviewStale:
            "This hold review is out of date. Review it again before applying."
        case .keychainFailure(let operation, let status):
            "Actualist could not \(operation) Keychain data. OSStatus: \(status)"
        case .hybridLogicalClockOverflow:
            "Actualist could not create a local sync timestamp because the clock counter overflowed."
        case .localWriteSuperseded:
            "Actualist did not save the change because a newer local value already exists."
        case .importedTransactionConflict:
            "Some of these transactions were already imported by another update. Nothing was saved. Try again."
        case .syncUploadNotConfirmed(let count):
            "The Actual server did not confirm \(count) uploaded sync message\(count == 1 ? "" : "s"). The changes remain pending on this device."
        case .unauthenticatedPlaintextEnvelope:
            "The Actual server returned unauthenticated plaintext data for an encrypted budget."
        case .clockDrift:
            "Sync stopped because a change is dated more than 5 minutes in the future. The clock on this device or on the server is wrong. Check Date & Time on both, then try again."
        case .invalidSyncTimestamp:
            "Sync stopped because the Actual server sent a change with an invalid timestamp. Nothing from that sync was applied."
        case .undecryptableMessage:
            "Actualist could not decrypt a change from the Actual server. Check the budget's encryption password."
        case .invalidSyncValue:
            "Actualist found a synced value it could not read."
        case .syncOutOfSync:
            "Sync could not finish because this device and the Actual server disagree about which changes exist. Your changes are still on this device. Try again later, or download the budget again if this keeps happening."
        }
    }
}
