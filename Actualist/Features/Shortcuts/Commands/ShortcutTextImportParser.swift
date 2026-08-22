import Foundation

enum ShortcutTransactionDirection: String, Sendable {
    case spend
    case inflow
    case transfer
}

struct ShortcutTextImportParse: Equatable, Sendable {
    var amountMinorUnits: Int
    var direction: ShortcutTransactionDirection?
    var payeeText: String?
    var accountText: String?
    var destinationAccountText: String?
    var categoryText: String?
    var notes: String?
    var date: Date?
}

enum ShortcutTextImportParser {
    static func parse(_ text: String) throws -> ShortcutTextImportParse {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ShortcutsError.textImportAmountMissing
        }

        if let transfer = parseTransfer(normalized) {
            return transfer
        }

        let withoutDates = strippingDates(from: normalized)
        guard let amountMatch = firstAmount(in: withoutDates) else {
            throw ShortcutsError.textImportAmountMissing
        }
        let amountMinorUnits = try ShortcutMoney.minorUnits(from: amountMatch.decimal)

        var working = removing(amountMatch.raw, from: withoutDates)
        let direction = parseDirection(in: working) ?? .spend
        working = removingKeywords(from: working)

        var payeeText = capture(after: ["on", "at"], in: &working)
        var accountText = capture(after: ["in"], in: &working)
        let leftovers = working
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        var categoryText: String?
        if payeeText == nil, let first = leftovers.first {
            payeeText = first
            assignTrailingTokens(Array(leftovers.dropFirst()), account: &accountText, category: &categoryText)
        } else {
            assignTrailingTokens(leftovers, account: &accountText, category: &categoryText)
        }

        return ShortcutTextImportParse(
            amountMinorUnits: amountMinorUnits,
            direction: direction,
            payeeText: payeeText,
            accountText: accountText,
            destinationAccountText: nil,
            categoryText: categoryText,
            notes: nil,
            date: nil
        )
    }

    private static func parseTransfer(_ text: String) -> ShortcutTextImportParse? {
        let pattern = #"^transfer\s+(\$?[\d,]+(?:\.\d{1,2})?)\s+from\s+(.+?)\s+to\s+(.+)$"#
        guard let match = firstMatch(pattern, in: text, options: [.caseInsensitive]) else {
            return nil
        }
        guard let amountText = match.capture(1, in: text),
              let amount = decimal(from: amountText),
              let minorUnits = try? ShortcutMoney.minorUnits(from: amount) else {
            return nil
        }
        let source = match.capture(2, in: text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = match.capture(3, in: text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutTextImportParse(
            amountMinorUnits: minorUnits,
            direction: .transfer,
            payeeText: nil,
            accountText: source,
            destinationAccountText: destination,
            categoryText: nil,
            notes: nil,
            date: nil
        )
    }

    private static func parseDirection(in text: String) -> ShortcutTransactionDirection? {
        let lower = text.lowercased()
        if lower.contains("received") || lower.contains("inflow") || lower.contains("got") {
            return .inflow
        }
        if lower.contains("spent") || lower.contains("spend") {
            return .spend
        }
        return nil
    }

    private static func firstAmount(in text: String) -> (raw: String, decimal: Decimal)? {
        let pattern = #"\$?-?[\d,]+(?:\.\d{1,2})?"#
        guard let match = firstMatch(pattern, in: text),
              let raw = match.capture(0, in: text),
              let decimal = decimal(from: raw) else {
            return nil
        }
        return (raw, decimal)
    }

    private static func decimal(from raw: String) -> Decimal? {
        let cleaned = raw.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned)
    }

    private static func removing(_ snippet: String, from text: String) -> String {
        text.replacingOccurrences(of: snippet, with: " ", options: [.caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingKeywords(from text: String) -> String {
        let keywords = ["spent", "spend", "received", "inflow", "got"]
        var working = text
        for keyword in keywords {
            working = removing(keyword, from: working)
        }
        return working
    }

    private static func strippingDates(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\b\d{4}-\d{1,2}-\d{1,2}\b"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capture(after prefixes: [String], in text: inout String) -> String? {
        for prefix in prefixes {
            let pattern = #"\b"#
                + NSRegularExpression.escapedPattern(for: prefix)
                + #"\s+(.+?)(?=\s+(?:in|on|at)\b|$)"#
            guard let match = firstMatch(pattern, in: text, options: [.caseInsensitive]),
                  let value = match.capture(1, in: text) else {
                continue
            }
            text = removing(match.capture(0, in: text) ?? "", from: text)
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func assignTrailingTokens(
        _ tokens: [String],
        account: inout String?,
        category: inout String?
    ) {
        guard !tokens.isEmpty else {
            return
        }
        if tokens.count == 1 {
            if account == nil {
                category = category ?? tokens[0]
            }
            return
        }
        if category == nil {
            category = tokens[0]
        }
        if account == nil {
            account = tokens[1]
        }
    }

    private static func firstMatch(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }
}

private extension NSTextCheckingResult {
    func capture(_ index: Int, in text: String) -> String? {
        guard index < numberOfRanges else {
            return nil
        }
        let range = self.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
