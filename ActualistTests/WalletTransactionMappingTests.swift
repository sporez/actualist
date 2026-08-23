import Foundation
import Testing
@testable import Actualist

struct WalletTransactionMappingTests {
    @Test func mapsStandardDebitToNegativeCents() throws {
        let candidate = try #require(
            WalletTransactionMapper.map(
                fields(
                    amount: Decimal(string: "12.50")!,
                    indicator: .debit,
                    merchantName: "Cafe",
                    status: .booked
                )
            )
        )

        #expect(candidate.amountMinorUnits == -1_250)
        #expect(candidate.payeeName == "Cafe")
        #expect(candidate.isCleared)
        #expect(candidate.financialID == Self.fixedID.uuidString.lowercased())
    }

    @Test func mapsCreditToPositiveCents() throws {
        let candidate = try #require(
            WalletTransactionMapper.map(
                fields(
                    amount: Decimal(string: "40.00")!,
                    indicator: .credit,
                    merchantName: "Refund",
                    status: .pending
                )
            )
        )

        #expect(candidate.amountMinorUnits == 4_000)
        #expect(!candidate.isCleared)
    }

    @Test func rejectedStatusReturnsNil() {
        #expect(
            WalletTransactionMapper.map(
                fields(
                    amount: Decimal(string: "9.99")!,
                    indicator: .debit,
                    merchantName: "Voided",
                    status: .rejected
                )
            ) == nil
        )
    }

    @Test func emptyMerchantNameFallsBackToDescription() throws {
        let candidate = try #require(
            WalletTransactionMapper.map(
                fields(
                    amount: Decimal(string: "3.00")!,
                    indicator: .debit,
                    merchantName: "  ",
                    description: "Corner Market",
                    status: .authorized
                )
            )
        )

        #expect(candidate.payeeName == "Corner Market")
        #expect(!candidate.isCleared)
    }

    @Test func normalizesProcessorPrefixesAndStoreNumbers() {
        #expect(WalletTransactionMapper.normalizePayee("SQ * SQUARE COFFEE #12345") == "Square Coffee")
        #expect(WalletTransactionMapper.normalizePayee("tst * bagel shop #9") == "Bagel Shop")
        #expect(WalletTransactionMapper.normalizePayee("TST*STARBUCKS") == "Starbucks")
        #expect(WalletTransactionMapper.normalizePayee("PAYPAL * VENDOR") == "Vendor")
        #expect(WalletTransactionMapper.normalizePayee("SP MERCHANT") == "Merchant")
    }

    @Test func amountOverflowAndNonFiniteValuesReturnNil() {
        #expect(
            WalletTransactionMapper.map(
                fields(
                    amount: Decimal.greatestFiniteMagnitude,
                    indicator: .debit,
                    merchantName: "Huge",
                    status: .booked
                )
            ) == nil
        )
        #expect(
            WalletTransactionMapper.map(
                fields(
                    amount: Decimal.nan,
                    indicator: .credit,
                    merchantName: "Broken",
                    status: .booked
                )
            ) == nil
        )
        #expect(
            WalletTransactionMapper.signedMinorUnits(amount: 0, indicator: .debit) == nil
        )
    }

    @Test func roundsHalfAwayFromZero() {
        #expect(
            WalletTransactionMapper.signedMinorUnits(
                amount: Decimal(string: "12.555")!,
                indicator: .credit
            ) == 1_256
        )
        #expect(
            WalletTransactionMapper.signedMinorUnits(
                amount: Decimal(string: "12.554")!,
                indicator: .debit
            ) == -1_255
        )
    }

    @Test func importSummaryUsesPluralization() {
        #expect(
            WalletTransactionImportResult(importedCount: 1, duplicateCount: 0).summaryText
                == "Added 1 transaction, skipped 0 already on this account."
        )
        #expect(
            WalletTransactionImportResult(importedCount: 3, duplicateCount: 2).summaryText
                == "Added 3 transactions, skipped 2 already on this account."
        )
        #expect(
            WalletTransactionImportResult(importedCount: 0, duplicateCount: 1).summaryText
                == "Added 0 transactions, skipped 1 already on this account."
        )
    }

    private static let fixedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func fields(
        amount: Decimal,
        indicator: WalletCreditDebitIndicator,
        merchantName: String?,
        description: String = "Original description",
        status: WalletTransactionStatus
    ) -> WalletTransactionFields {
        WalletTransactionFields(
            id: Self.fixedID,
            amount: amount,
            creditDebitIndicator: indicator,
            merchantName: merchantName,
            transactionDescription: description,
            transactionDate: Date(timeIntervalSince1970: 1_783_497_600),
            status: status
        )
    }
}

struct WalletImportAccountPreferenceTests {
    @Test func prefersTheConfiguredDefaultWhenItIsOpen() {
        #expect(
            WalletImportViewModel.preferredAccountID(
                defaultAccountID: "credit",
                openAccountIDs: ["checking", "credit", "savings"]
            ) == "credit"
        )
    }

    @Test func fallsBackToTheFirstOpenAccountWhenDefaultIsMissing() {
        #expect(
            WalletImportViewModel.preferredAccountID(
                defaultAccountID: nil,
                openAccountIDs: ["checking", "credit"]
            ) == "checking"
        )
        #expect(
            WalletImportViewModel.preferredAccountID(
                defaultAccountID: "closed",
                openAccountIDs: ["checking", "credit"]
            ) == "checking"
        )
    }
}
