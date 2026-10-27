import SwiftUI

/// What sharing a saved transaction sends: a link that opens it and a card
/// showing its payee, amount and date. They are the real values even with
/// privacy mode on, because the user chooses to send them.
struct TransactionShareContent: Equatable, Sendable, Identifiable {
    /// The caption Messages shows under the card; the card already carries the details.
    static let previewTitle = "Shared from Actualist"

    let link: SharedTransactionLink
    let payee: String
    let amount: String
    let date: String

    var id: String { link.transactionID }

    init?(
        transactionID: String?,
        payee: String,
        amountMinorUnits: Int,
        date: Date?,
        currency: BudgetCurrency,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        guard let transactionID, let link = SharedTransactionLink(transactionID: transactionID),
              let date else { return nil }
        self.link = link
        let trimmedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        self.payee = trimmedPayee.isEmpty ? "Transaction" : trimmedPayee
        let magnitude = currency.formatted(abs(amountMinorUnits))
        amount = amountMinorUnits > 0 ? "+\(magnitude)" : magnitude
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated)
            .day()
            .locale(locale)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        self.date = date.formatted(style)
    }

    func url(installation: AppInstallationIdentity = .current) -> URL {
        link.url(.universal, installation: installation)
    }
}

extension TransactionShareContent {
    /// The editor's values match the saved transaction only while nothing is unsaved.
    @MainActor
    init?(editor: TransactionEditorViewModel) {
        guard editor.isEditing, !editor.hasUnsavedChanges else { return nil }
        self.init(
            transactionID: editor.mutationCoordinator.transactionID,
            payee: editor.payeeName,
            amountMinorUnits: editor.signedAmountCents,
            date: editor.date,
            currency: editor.currency
        )
    }

    init?(row: AccountTransactionRowPresentation, currency: BudgetCurrency) {
        self.init(
            transactionID: row.transaction.id,
            payee: row.payeeName,
            amountMinorUnits: row.transaction.amount ?? 0,
            date: row.transaction.date.actualDate,
            currency: currency
        )
    }
}

/// The card shown in the share sheet and in the recipient's conversation.
struct TransactionShareCard: View {
    let content: TransactionShareContent

    /// Square, because the share sheet crops its preview to a square.
    var body: some View {
        VStack(spacing: 10) {
            Text(content.payee)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(ActualistTheme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(content.amount)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(content.date)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .padding(28)
        .frame(width: 320, height: 320)
        .background(ActualistTheme.background)
        .environment(\.colorScheme, .dark)
    }
}
