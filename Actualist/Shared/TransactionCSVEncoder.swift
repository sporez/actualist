import CoreTransferable
import Foundation

struct TransactionCSVEncoder {
    private static let headers = [
        "Account", "Date", "Payee", "Notes", "Category_Group", "Category", "Amount", "Split_Amount", "Cleared",
    ]
    private static let formulaTriggers: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    func encode(
        _ rows: [TransactionCSVExportRow],
        generatedAt: Date = Date(),
        calendar: Calendar = Self.utcCalendar
    ) -> TransactionCSVExport {
        let childrenByParent = Dictionary(grouping: rows.filter(\.isChild), by: \.familyID)
        var output = [Self.headers.map(Self.csvCell).joined(separator: ",")]
        output.reserveCapacity(rows.count + 1)

        for row in rows {
            let siblingRows = childrenByParent[row.familyID] ?? []
            let childNumber = siblingRows.firstIndex(where: { $0.id == row.id }).map { $0 + 1 } ?? 0
            let notes: String? = if row.isParent {
                "(SPLIT INTO \(siblingRows.count)) \(row.notes ?? "")"
            } else if row.isChild {
                "(SPLIT \(childNumber) OF \(siblingRows.count)) \(row.notes ?? "")"
            } else {
                row.notes
            }

            let amount = row.isParent ? "0" : Self.actualAmount(row.amountMinorUnits)
            let splitAmount = row.isParent ? Self.actualAmount(row.amountMinorUnits) : "0"
            let cleared = row.isReconciled ? "Reconciled" : (row.isCleared ? "Cleared" : "Not cleared")
            let fields = [
                Self.spreadsheetText(row.accountName), Self.spreadsheetText(row.date), Self.spreadsheetText(row.payeeName),
                Self.spreadsheetText(notes ?? ""), Self.spreadsheetText(row.categoryGroupName),
                Self.spreadsheetText(row.categoryName), amount, splitAmount, cleared,
            ]
            output.append(fields.map(Self.csvCell).joined(separator: ","))
        }

        // Pinned Actual 26.9.0 uses csv-stringify 6.8.x defaults: LF records and a final LF.
        let csv = output.joined(separator: "\n") + "\n"
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: generatedAt)
        let filename = String(
            format: "Transactions-%04d%02d%02d-%02d%02d%02d.csv",
            parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return TransactionCSVExport(
            suggestedFilename: filename,
            data: Data(csv.utf8),
            exportedFamilyCount: Set(rows.map(\.familyID)).count,
            exportedRowCount: rows.count
        )
    }

    private static func spreadsheetText(_ value: String) -> String {
        guard let first = value.unicodeScalars.first, formulaTriggers.contains(first) else { return value }
        return "'" + value
    }

    private static func csvCell(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func actualAmount(_ minorUnits: Int) -> String {
        NSDecimalNumber(decimal: Decimal(minorUnits) / Decimal(100)).stringValue
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

struct TransactionCSVTransfer: Equatable, Sendable, Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { $0.data }
            .suggestedFileName { $0.filename }
    }
}
