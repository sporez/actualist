import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// What sharing a saved transaction sends: a link that opens it, one line of
/// text, and a card. Payee, amount and date are the real values even with
/// privacy mode on, because the user chooses to send them.
struct TransactionShareContent: Equatable, Sendable {
    let link: SharedTransactionLink
    let payee: String
    let amount: String
    let date: String

    var message: String { "\(payee) · \(amount) · \(date)" }

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

/// The shared link. Exporting it asks the sender's own waiting changes to
/// upload, so the recipient's sync can find the transaction; the share
/// sheet never waits for that upload.
struct TransactionShareItem: Transferable, Sendable {
    let url: URL
    let requestUpload: @Sendable () -> Void

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (item: TransactionShareItem) in
            item.requestUpload()
            return item.url
        }
    }
}

/// The Share control for the editor toolbar and the row menu.
struct TransactionShareButton: View {
    @Environment(AppState.self) private var appState
    let content: TransactionShareContent

    var body: some View {
        let store = appState.localFirstStore
        ShareLink(
            item: TransactionShareItem(url: content.url()) {
                Task { @MainActor in await store.retryPendingLocalMessageFlush() }
            },
            subject: Text(content.payee),
            message: Text(content.message),
            preview: SharePreview(content.message, image: TransactionShareCardImage(content: content))
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

/// The card shown in the share sheet and, when Messages keeps it, in the
/// recipient's conversation.
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

/// The card as a PNG, drawn only when the share sheet asks for it, so a list
/// of rows with Share in their menus never draws one card per row.
struct TransactionShareCardImage: Transferable, Sendable {
    let content: TransactionShareContent

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { (image: TransactionShareCardImage) in
            try await image.pngData()
        }
    }

    @MainActor
    private func pngData() throws -> Data {
        let renderer = ImageRenderer(content: TransactionShareCard(content: content))
        renderer.scale = 2
        let data = NSMutableData()
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
