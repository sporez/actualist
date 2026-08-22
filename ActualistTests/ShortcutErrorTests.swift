import Foundation
import Testing
@testable import Actualist

struct ShortcutErrorTests {
    @Test func everyCaseHasUserFacingCopyWithoutInternalTokens() throws {
        let cases: [ShortcutsError] = [
            .shortcutsDisabled,
            .noBudgetSelected,
            .budgetFileMissing,
            .encryptedBudgetNeedsUnlock,
            .budgetBusy,
            .accountNotFound,
            .categoryNotFound,
            .payeeNotFound,
            .transactionNotFound,
            .amountMissing,
            .amountInvalid,
            .transferDestinationMissing,
            .defaultAccountMissing,
            .textImportAmountMissing,
            .ambiguousMatch,
            .unsupportedSplit,
            .unsupportedTransfer,
            .accountClosed,
            .currencyMismatch,
            .invalidName,
            .writeFailed,
            .templateUnsupported
        ]

        for error in cases {
            let copy = try #require(error.errorDescription)
            #expect(!copy.isEmpty)
            #expect(!copy.contains("/"))
            #expect(!copy.contains("token"))
            #expect(!copy.contains("Keychain"))
            #expect(!copy.contains("OSStatus"))
        }
    }

    @Test func mappingPreservesShortcutsErrorsAndTranslatesStoreErrors() {
        #expect(ShortcutsError.mapping(ShortcutsError.accountClosed) == .accountClosed)
        #expect(
            ShortcutsError.mapping(LocalFirstError.encryptedBudgetRequiresPassword) == .encryptedBudgetNeedsUnlock
        )
        #expect(ShortcutsError.mapping(LocalFirstError.invalidEncryptionKey) == .encryptedBudgetNeedsUnlock)
        #expect(ShortcutsError.mapping(LocalFirstError.invalidEncryptionPassword) == .encryptedBudgetNeedsUnlock)
        #expect(ShortcutsError.mapping(LocalFirstError.missingImportedDatabase) == .budgetFileMissing)
        #expect(ShortcutsError.mapping(LocalFirstError.missingBudgetFileID) == .budgetFileMissing)
        #expect(ShortcutsError.mapping(LocalFirstError.invalidBudgetFileID) == .budgetFileMissing)
        #expect(ShortcutsError.mapping(LocalFirstError.unsupportedSplitWrite) == .unsupportedSplit)
        #expect(ShortcutsError.mapping(LocalFirstError.unsupportedTransferWrite) == .unsupportedTransfer)
        #expect(ShortcutsError.mapping(LocalFirstError.budgetNotOpened) == .budgetBusy)
        #expect(ShortcutsError.mapping(LocalFirstError.invalidLocalWrite("missing category")) == .writeFailed)
        #expect(ShortcutsError.mapping(LocalFirstError.unsupportedWrite) == .writeFailed)
        #expect(ShortcutsError.mapping(LocalFirstError.unsupportedTemplate("goal")) == .templateUnsupported)
        #expect(ShortcutsError.mapping(LocalFirstError.missingSyncToken) == .writeFailed)
        #expect(ShortcutsError.mapping(LocalFirstError.missingSyncToken, fallback: .budgetFileMissing) == .budgetFileMissing)
        #expect(ShortcutsError.mapping(NSError(domain: "test", code: 1)) == .writeFailed)
    }
}
