import Foundation
import Testing
@testable import Actualist

struct TransactionShareContentTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private let locale = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func content(
        id: String? = "txn-1",
        payee: String = "Costco",
        amount: Int = -8412,
        on day: Date? = nil,
        currency: BudgetCurrency = .usd
    ) -> TransactionShareContent? {
        TransactionShareContent(
            transactionID: id,
            payee: payee,
            amountMinorUnits: amount,
            date: day ?? date(2026, 10, 20),
            currency: currency,
            now: date(2026, 10, 27),
            calendar: calendar,
            locale: locale
        )
    }

    @Test func spendingIsOneLineWithTheAmountAsAPositiveNumber() throws {
        let share = try #require(content())
        #expect(share.message == "Costco · \(BudgetCurrency.usd.formatted(8412)) · Oct 20")
        #expect(!share.amount.hasPrefix("-"))
    }

    @Test func incomeIsMarkedWithAPlus() throws {
        let share = try #require(content(amount: 120_000))
        #expect(share.amount == "+\(BudgetCurrency.usd.formatted(120_000))")
    }

    @Test func anotherYearIncludesTheYear() throws {
        let share = try #require(content(on: date(2025, 12, 31)))
        #expect(share.date == "Dec 31, 2025")
    }

    @Test func aPayeeLessRowStillReadsAsATransaction() throws {
        #expect(try #require(content(payee: "  ")).payee == "Transaction")
    }

    @Test func nothingToShareWithoutAUsableID() {
        #expect(content(id: nil) == nil)
        #expect(content(id: "") == nil)
        #expect(content(id: "has/slash") == nil)
    }

    @Test func eachInstallSharesItsOwnWebLink() throws {
        let share = try #require(content())
        #expect(share.url(installation: .production).absoluteString == "https://actualist.app/t#txn-1")
        #expect(share.url(installation: .development).absoluteString == "https://actualist.app/dev/t#txn-1")
    }

    @Test func aRowUsesItsProjectedPayeeAndStoredAmount() throws {
        let transaction = ActualTransaction(
            id: "din-1",
            account: "checking",
            date: "2026-08-27",
            amount: -5200,
            payee: "bistro",
            payeeName: "Bistro",
            importedPayee: nil,
            category: "dining",
            notes: nil,
            cleared: nil
        )
        let lookup = TransactionRowLookup(payeeNames: ["bistro": "Bistro Nove"])
        let row = AccountTransactionRowPresentation(
            transaction: transaction,
            semantics: TransactionRowSemantics.project(transaction, lookup: lookup),
            accountName: nil,
            isNew: false,
            scheduleConversionEntryPoint: nil
        )

        let share = try #require(TransactionShareContent(row: row, currency: .usd))

        #expect(share.payee == row.payeeName)
        #expect(share.link.transactionID == "din-1")
        #expect(share.amount == BudgetCurrency.usd.formatted(5200))
    }

    @Test @MainActor func theEditorSharesOnlyASavedUnchangedTransaction() throws {
        let transaction = ActualTransaction(
            id: "din-1",
            account: "checking",
            date: "2026-08-27",
            amount: -5200,
            payee: "bistro",
            payeeName: "Bistro Nove",
            importedPayee: nil,
            category: "dining",
            notes: nil,
            cleared: nil
        )
        #expect(TransactionShareContent(editor: TransactionEditorViewModel()) == nil)

        let editor = TransactionEditorViewModel(editing: transaction)
        editor.captureDraftBaselineIfNeeded()
        let share = try #require(TransactionShareContent(editor: editor))
        #expect(share.payee == "Bistro Nove")
        #expect(share.link.transactionID == "din-1")

        editor.notes = "Changed"
        #expect(TransactionShareContent(editor: editor) == nil)
    }
}
