import Foundation

enum LocalFirstRecoveryGuidance {
    static let encryptionPasswordNotice = """
        This encryption password cannot be recovered by Actualist. Store it securely somewhere \
        you can access if this device is lost or replaced. Actualist stores only the unlocked \
        budget key on this device, not the password. Neither is included in device backups.
        """
}

enum LocalFirstError: LocalizedError, Equatable {
    case missingServerURL
    case missingPassword
    case missingSyncToken
    case missingBudgetFileID
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
    /// A write broke an internal invariant. The string is a developer reason for
    /// tests and diagnostics; people see one generic sentence instead.
    case invalidLocalWrite(String)
    /// A change was refused for a reason the person can act on, such as a
    /// duplicate name. The string is a complete, plain sentence shown as is.
    case refusedChange(String)
    /// The budget file lacks a table or column the write needs. Deterministic per
    /// budget, so schedule posting refuses instead of failing the whole run.
    case schemaUnavailable(String)
    /// A row the write references (account, category, payee) is deleted, closed or
    /// missing. The user can fix it, unlike a schema gap.
    case referencedRowUnavailable(String)
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
    /// A change already stored on this device is dated more than five minutes
    /// ahead of this device's clock, so a new local change cannot be stamped
    /// after it. Local writes only; remote batches still report `clockDrift`.
    case storedChangeDatedInFuture(wallTime: String)
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
            "Enter your Actual server address."
        case .missingPassword:
            "Enter your Actual server password."
        case .missingSyncToken:
            "Sign in to the Actual server before loading budgets."
        case .missingBudgetFileID:
            "This budget is missing information Actualist needs. Reimport the budget."
        case .selectedBudgetUnavailable:
            "The selected budget is not on this Actual server."
        case .invalidBudgetFileID:
            "This budget is missing information Actualist needs. Reimport the budget."
        case .numericValueOutOfRange:
            "A number in this budget is too large for Actualist to handle."
        case .unsupportedWrite:
            "Actualist cannot make this change yet."
        case .unsupportedTransferWrite:
            "Actualist cannot change this transfer."
        case .unsupportedSplitWrite:
            "Actualist cannot change this split transaction."
        case .encryptedBudgetRequiresPassword:
            "This budget is encrypted. Enter its encryption password to open it."
        case .invalidEncryptionPassword:
            "That encryption password did not unlock this budget. Check it and try again."
        case .invalidEncryptionKey:
            "Actualist could not unlock this budget. Enter its encryption password again."
        case .invalidEncryptedPayload:
            "Actualist could not read this budget's encrypted data from the server. Check the encryption password."
        case .budgetEncryptionChanged:
            "This budget's encryption changed on the server. Reopen the budget and enter its current encryption password."
        case .unsupportedEncryptionAlgorithm:
            "Actualist does not support this budget's type of encryption."
        case .missingImportedDatabase:
            "The imported budget does not contain any budget data."
        case .invalidDownloadedBudget:
            "Actualist could not import the downloaded budget."
        case .localBudgetHardeningFailed:
            "Actualist could not protect this budget's data on this device."
        case .reimportRollbackFailed:
            "The reimport failed, and Actualist could not restore your previous copy. Your previous copy is still on this device. Try again."
        case .remoteDataLimitExceeded:
            "The server sent more data than Actualist can handle."
        case .insufficientStorage:
            "There is not enough free space on this device to import the budget."
        case .invalidLocalWrite:
            "Actualist could not save this change. Try again."
        case .refusedChange(let reason):
            reason
        case .schemaUnavailable:
            "Actualist cannot make this change in this budget yet."
        case .referencedRowUnavailable:
            "An account, category, or payee this change uses was deleted or closed. Check it and try again."
        case .actionUndoBlocked(let reason):
            reason
        case .budgetNotOpened:
            "Open a budget first."
        case .unsupportedTemplate:
            "Actualist cannot apply this budget template yet."
        case .budgetTemplateReviewStale:
            "This template preview is out of date. Review it again before applying."
        case .budgetHoldReviewStale:
            "This Hold for Next Month preview is out of date. Review it again before applying."
        case .keychainFailure:
            "Actualist could not access your saved sign-in on this device. Unlock the device and try again."
        case .hybridLogicalClockOverflow:
            "Actualist could not save this change. Try again."
        case .localWriteSuperseded:
            "Actualist did not save this change because a newer change already exists on this device."
        case .importedTransactionConflict:
            "Some of these transactions were already imported by another update. Nothing was saved. Try again."
        case .syncUploadNotConfirmed(let count):
            "The Actual server did not confirm \(count) change\(count == 1 ? "" : "s"). The change\(count == 1 ? " is" : "s are") still saved on this device and will sync later."
        case .unauthenticatedPlaintextEnvelope:
            "The Actual server sent unprotected data for an encrypted budget. Actualist stopped syncing for your safety."
        case .clockDrift:
            "Sync stopped because a change is dated more than 5 minutes in the future. The clock on this device or the server is wrong. Check the date and time on both, then try again."
        case .storedChangeDatedInFuture:
            "Actualist did not save this change because the clock on this device looks wrong. Check Date & Time in Settings. If it is correct, reimport the budget."
        case .invalidSyncTimestamp:
            "Sync stopped because the Actual server sent a change Actualist could not read. Nothing from that sync was applied."
        case .undecryptableMessage:
            "Actualist could not unlock a change from the Actual server. Check the budget's encryption password."
        case .invalidSyncValue:
            "Actualist found synced data it could not read."
        case .syncOutOfSync:
            "Sync could not finish because this device and the Actual server do not agree on the latest changes. Your changes are still on this device. Try again later, or reimport the budget if this keeps happening."
        }
    }
}
