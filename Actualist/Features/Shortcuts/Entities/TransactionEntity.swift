import AppIntents
import Foundation

struct TransactionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transaction"
    static let defaultQuery = TransactionEntityQuery()

    var id: String

    @Property(title: "Amount")
    var amount: IntentCurrencyAmount?

    @Property(title: "Date")
    var date: Date?

    @Property(title: "Payee")
    var payee: String

    @Property(title: "Account")
    var account: String

    @Property(title: "Category")
    var category: String?

    @Property(title: "Notes")
    var notes: String?

    @Property(title: "Cleared")
    var cleared: Bool

    @Property(title: "Transfer")
    var isTransfer: Bool

    var displayRepresentation: DisplayRepresentation {
        let amountText = amount.map {
            ShortcutMoney.spoken($0, currency: BudgetCurrency.catalog(code: $0.currencyCode))
        }
            ?? "—"
        return DisplayRepresentation(title: "\(payee) · \(amountText) · \(dateText)")
    }

    init(
        id: String,
        amount: IntentCurrencyAmount?,
        date: Date?,
        payee: String,
        account: String,
        category: String?,
        notes: String?,
        cleared: Bool,
        isTransfer: Bool
    ) {
        self.id = id
        self.amount = amount
        self.date = date
        self.payee = payee
        self.account = account
        self.category = category
        self.notes = notes
        self.cleared = cleared
        self.isTransfer = isTransfer
    }

    static func make(
        from transaction: ActualTransaction,
        maps: TransactionNameMaps,
        currency: BudgetCurrency? = nil
    ) -> TransactionEntity? {
        guard let id = transaction.id, !id.isEmpty else {
            return nil
        }
        let payeeName = transaction.payeeName
            ?? transaction.payee.flatMap { maps.payeeNames[$0] }
            ?? "Unknown payee"
        return TransactionEntity(
            id: id,
            amount: transaction.amount.map { ShortcutMoney.intentAmount(minorUnits: $0, currency: currency) },
            date: transaction.date.actualDate,
            payee: payeeName,
            account: maps.accountNames[transaction.account] ?? transaction.account,
            category: transaction.category.flatMap { maps.categoryNames[$0] },
            notes: transaction.notes,
            cleared: transaction.cleared?.boolValue ?? false,
            isTransfer: transaction.payee.map { maps.transferPayeeIDs.contains($0) } ?? false
        )
    }

    private var dateText: String {
        guard let date else {
            return "Unknown date"
        }
        return ReportCalendar.longDayTitle(ReportCalendar.dayID(for: date))
    }
}

struct TransactionEntityQuery: EntityQuery {
    @Dependency var session: ShortcutsBudgetSession

    func entities(for identifiers: [TransactionEntity.ID]) async throws -> [TransactionEntity] {
        try await session.transactions(ids: identifiers)
    }

    func suggestedEntities() async throws -> [TransactionEntity] {
        try await session.transactions(limit: ShortcutTransactionLimits.suggested)
    }
}

extension TransactionEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [TransactionEntity] {
        try await session.transactions(
            search: string,
            limit: ShortcutTransactionLimits.suggested
        )
    }
}
