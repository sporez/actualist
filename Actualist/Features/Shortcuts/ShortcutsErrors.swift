import Foundation

enum ShortcutsError: LocalizedError, Equatable {
    case shortcutsDisabled
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
    case accountClosed
    case currencyMismatch
    case invalidName
    case writeFailed
    case templateUnsupported

    var errorDescription: String? {
        switch self {
        case .shortcutsDisabled:
            "Shortcuts are turned off in Privacy."
        case .noBudgetSelected:
            "No budget is selected. Open Actualist and choose a budget first."
        case .budgetFileMissing:
            "The budget file is not on this device. Reopen the budget in Actualist."
        case .encryptedBudgetNeedsUnlock:
            "This encrypted budget needs to be unlocked in Actualist first."
        case .budgetBusy:
            "Actualist is switching budgets. Try again in a moment."
        case .accountNotFound:
            "That account could not be found in the selected budget."
        case .categoryNotFound:
            "That category could not be found in the selected budget."
        case .payeeNotFound:
            "That payee could not be found in the selected budget."
        case .transactionNotFound:
            "That transaction could not be found in the selected budget."
        case .amountMissing:
            "Enter an amount."
        case .amountInvalid:
            "That amount is not valid."
        case .transferDestinationMissing:
            "Choose a destination account for the transfer."
        case .defaultAccountMissing:
            "Choose an account or set a default account in Settings."
        case .textImportAmountMissing:
            "That text does not include an amount."
        case .ambiguousMatch:
            "That name matches more than one item. Be more specific."
        case .unsupportedSplit:
            "Split transactions can only be changed in Actualist. Shortcuts will not change a split."
        case .unsupportedTransfer:
            "That transfer cannot be changed that way. Open it in Actualist."
        case .accountClosed:
            "That account is closed. Choose an open account."
        case .currencyMismatch:
            "Use the same currency as this iPhone."
        case .invalidName:
            "Enter a name."
        case .writeFailed:
            "Actualist could not apply that change."
        case .templateUnsupported:
            "That budget template cannot be applied in Shortcuts. Open Actualist to apply it."
        }
    }

    static func mapping(_ error: Error, fallback: ShortcutsError = .writeFailed) -> ShortcutsError {
        if let error = error as? ShortcutsError {
            return error
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
            case .invalidLocalWrite, .unsupportedWrite:
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
