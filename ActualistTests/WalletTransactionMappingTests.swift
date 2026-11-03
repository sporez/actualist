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
        #expect(candidate.importedPayee == "Cafe")
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

    @Test func keepsRawImportedPayeeSeparateFromNormalizedDisplayPayee() throws {
        let candidate = try #require(
            WalletTransactionMapper.map(
                fields(
                    amount: Decimal(string: "8.50")!,
                    indicator: .debit,
                    merchantName: "  SQ * SQUARE COFFEE #12345  ",
                    status: .booked
                )
            )
        )

        #expect(candidate.importedPayee == "SQ * SQUARE COFFEE #12345")
        #expect(candidate.payeeName == "Square Coffee")
        let reconcile = WalletTransactionMapper.reconcileCandidate(from: candidate, payeeID: nil)
        #expect(reconcile.importedPayee == "SQ * SQUARE COFFEE #12345")
        #expect(reconcile.payeeName == "Square Coffee")
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

    @Test func applyingImportPreviewKeepsExactRuleSplitsIncludingOneChild() {
        let draft = TransactionDraft(
            accountID: "checking",
            date: Date(timeIntervalSince1970: 1_783_497_600),
            amountMinorUnits: -1_000,
            payeeID: nil,
            payeeName: "Split Cafe",
            categoryID: "dining",
            notes: "imported",
            cleared: true,
            isTransfer: false,
            importedPayee: "SPLIT CAFE",
            importedID: "fin-1"
        )
        let splits = [
            TransactionSplitDraft(
                id: nil,
                categoryID: "groceries",
                categoryName: "Groceries",
                amountMinorUnits: -1_000,
                payeeID: .value(nil),
                notes: .value("child note"),
                sortOrder: .value(-1)
            )
        ]
        let projected = TransactionRulePreviewProjection.applying(
            TransactionRulePreview(
                categoryID: "groceries",
                notes: "imported",
                splits: splits
            ),
            to: draft
        )

        #expect(projected.categoryID == nil)
        #expect(projected.isParent)
        #expect(projected.splits == splits)
        #expect(projected.importedID == "fin-1")
        #expect(projected.importedPayee == "SPLIT CAFE")
    }

    @Test func importSummaryUsesPluralization() {
        #expect(
            WalletTransactionImportResult(addedCount: 1, matchedCount: 0).summaryText
                == "Added 1 transaction, found 0 already on this account."
        )
        #expect(
            WalletTransactionImportResult(addedCount: 3, matchedCount: 2).summaryText
                == "Added 3 transactions, found 2 already on this account."
        )
        #expect(
            WalletTransactionImportResult(addedCount: 0, matchedCount: 1, skippedCount: 2).summaryText
                == "Added 0 transactions, found 1 already on this account. Skipped 2."
        )
    }

    /// The match window and rules see the local calendar day Wallet import has
    /// always written, also east of UTC where local midnight is the day before in UTC.
    @Test(arguments: ["America/New_York", "Pacific/Auckland", "Pacific/Kiritimati", "Etc/GMT+12"])
    func reconcileCandidateUsesTheLocalCalendarDay(identifier: String) throws {
        let zone = try #require(TimeZone(identifier: identifier))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        for hour in [0, 12, 23] {
            let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: hour, minute: 30)))
            let candidate = try #require(WalletTransactionMapper.map(WalletTransactionFields(
                id: Self.fixedID,
                amount: 90,
                creditDebitIndicator: .debit,
                merchantName: "Utility",
                transactionDescription: "Utility",
                transactionDate: date,
                status: .pending
            )))
            let reconcile = WalletTransactionMapper.reconcileCandidate(
                from: candidate, payeeID: "payee-1", timeZone: zone
            )
            #expect(reconcile.dayID == "20261019")
            #expect(reconcile.financialID == Self.fixedID.uuidString.lowercased())
            #expect(reconcile.amountMinorUnits == -9_000)
            #expect(reconcile.payeeID == "payee-1")
            #expect(reconcile.cleared == false)
            #expect(reconcile.categoryID == nil)
            let draftDate = try #require(BankSyncAmounts.date(fromDayID: reconcile.dayID, timeZone: zone))
            #expect(try BudgetDatabase.actualDateValue(draftDate, timeZone: zone) == 20261019)
        }
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
