import Foundation
import Security

enum ShortcutsError: LocalizedError, Equatable {
    case shortcutsDisabled
    case deviceLocked
    case noBudgetSelected
    case budgetFileMissing
    case encryptedBudgetNeedsUnlock
    case budgetBusy
    case accountNotFound
    case categoryNotFound
    case payeeNotFound
    case transactionNotFound
    case amountMissing
    case amountInvalid
    case transferDestinationMissing
    case defaultAccountMissing
    case textImportAmountMissing
    case ambiguousMatch
    case unsupportedSplit
    case unsupportedTransfer
    case reconciledTransaction
    case accountClosed
    case currencyMismatch
    case invalidName
    case writeFailed
    case templateUnsupported
    case trackingActionUnsupported
    case metricUnavailable

    var errorDescription: String? {
        switch self {
        case .shortcutsDisabled:
            "Shortcuts are turned off. Turn on Allow Shortcuts & Siri in Actualist under Settings > Privacy."
        case .deviceLocked:
            "Actualist cannot open this budget while this device is locked. Unlock the device and try again."
        case .noBudgetSelected:
            "No budget is selected. Open Actualist and choose a budget first."
        case .budgetFileMissing:
            "This budget is not on this device yet. Open it in Actualist first."
        case .encryptedBudgetNeedsUnlock:
            "This encrypted budget needs to be unlocked in Actualist first."
        case .budgetBusy:
            "Actualist is switching budgets. Try again in a moment."
        case .accountNotFound:
            "Actualist could not find that account in the selected budget."
        case .categoryNotFound:
            "Actualist could not find that category in the selected budget."
        case .payeeNotFound:
            "Actualist could not find that payee in the selected budget."
        case .transactionNotFound:
            "Actualist could not find that transaction in the selected budget."
        case .amountMissing:
            "Enter an amount."
        case .amountInvalid:
            "That amount is not valid. Enter a number."
        case .transferDestinationMissing:
            "Choose a destination account for the transfer."
        case .defaultAccountMissing:
            "Choose an account or set a default account in Settings."
        case .textImportAmountMissing:
            "That text does not include an amount. Add one and try again."
        case .ambiguousMatch:
            "That name matches more than one item. Be more specific."
        case .unsupportedSplit:
            "Shortcuts cannot change split transactions. Open the transaction in Actualist to change it."
        case .unsupportedTransfer:
            "Shortcuts cannot change that transfer. Open it in Actualist to change it."
        case .reconciledTransaction:
            "That transaction is reconciled. Open it in Actualist to change it."
        case .accountClosed:
            "That account is closed. Choose an open account."
        case .currencyMismatch:
            "The amount must use your budget's currency."
        case .invalidName:
            "Enter a name."
        case .writeFailed:
            "Actualist could not save that change. Try again."
        case .trackingActionUnsupported:
            "Tracking budgets do not have Move Money or To Budget. Use Set Category Budget or Get Budget Summary instead."
        case .metricUnavailable:
            "That metric is not available for this category. Use Balance for expenses in a tracking budget, or Received for income."
        case .templateUnsupported:
            "Shortcuts cannot apply that budget template. Open Actualist to apply it."
        }
    }

    static func mapping(_ error: Error, fallback: ShortcutsError = .writeFailed) -> ShortcutsError {
        if let error = error as? ShortcutsError {
            return error
        }
        // A session change cancelled the open or write; the budget is not missing.
        if error.isCancellation {
            return .budgetBusy
        }
        if error is ReconciledTransactionMutationError {
            return .reconciledTransaction
        }
        // A locked device refuses Keychain items that were never promoted to
        // after-first-unlock; an encrypted budget reads its key to open.
        if error as? KeychainReadError == .unavailable(errSecInteractionNotAllowed) {
            return .deviceLocked
        }
        if let error = error as? LocalFirstError {
            switch error {
            case .encryptedBudgetRequiresPassword, .invalidEncryptionKey, .invalidEncryptionPassword:
                return .encryptedBudgetNeedsUnlock
            case .missingImportedDatabase, .missingBudgetFileID, .invalidBudgetFileID:
                return .budgetFileMissing
            case .unsupportedSplitWrite:
                return .unsupportedSplit
            case .unsupportedTransferWrite:
                return .unsupportedTransfer
            case .budgetNotOpened:
                return .budgetBusy
            case .invalidLocalWrite, .schemaUnavailable, .referencedRowUnavailable, .unsupportedWrite:
                return .writeFailed
            case .unsupportedTemplate:
                return .templateUnsupported
            default:
                return fallback
            }
        }
        return fallback
    }
}
