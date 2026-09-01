import Foundation

struct ActualNoteTarget: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case category
        case categoryGroup
        case account
        case budgetMonth
    }

    let kind: Kind
    let entityID: String
    let title: String

    var id: String { "\(kind.rawValue):\(entityID)" }

    var noteID: String {
        switch kind {
        case .category, .categoryGroup:
            entityID
        case .account:
            "account-\(entityID)"
        case .budgetMonth:
            "budget-\(entityID)"
        }
    }

    static func category(id: String, title: String) -> ActualNoteTarget? {
        make(kind: .category, id: id, title: title)
    }

    static func categoryGroup(id: String, title: String) -> ActualNoteTarget? {
        make(kind: .categoryGroup, id: id, title: title)
    }

    static func account(id: String, title: String) -> ActualNoteTarget? {
        make(kind: .account, id: id, title: title)
    }

    static func budgetMonth(month: String, title: String) -> ActualNoteTarget? {
        make(kind: .budgetMonth, id: month, title: title)
    }

    private static func make(kind: Kind, id: String, title: String) -> ActualNoteTarget? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return nil
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ActualNoteTarget(
            kind: kind,
            entityID: trimmedID,
            title: trimmedTitle.isEmpty ? "Notes" : trimmedTitle
        )
    }
}

struct ActualNotePresentation: Equatable, Sendable {
    /// Shown above the notes editor. Keep in sync with the parser subset.
    static let editorSyntaxHint = "Supports **bold**, *italic*, and `code`. Line breaks are kept."

    let attributedText: AttributedString

    init?(userBody: String?) {
        guard let userBody else {
            return nil
        }
        let source = userBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return nil
        }

        let displaySource = Self.displayMarkdownSource(from: source)
        let parsed = try? AttributedString(
            markdown: displaySource,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )
        attributedText = parsed.map(Self.removingLinks) ?? AttributedString(source)
    }

    private static func removingLinks(from markdown: AttributedString) -> AttributedString {
        var output = AttributedString()
        for run in markdown.runs {
            var piece = AttributedString(String(markdown[run.range].characters))
            if let intent = run.inlinePresentationIntent {
                piece.inlinePresentationIntent = intent
            }
            output += piece
        }
        return output
    }

    /// Notes stay local-first display text: unwrap images, links, and autolinks
    /// before Foundation parses Markdown so the result has no tappable URL.
    static func displayMarkdownSource(from source: String) -> String {
        var result = source
        result = replacing(
            pattern: #"!\[([^\]]*)\]\([^)]*\)"#,
            in: result,
            with: "$1"
        )
        result = replacing(
            pattern: #"\[([^\]]*)\]\([^)]*\)"#,
            in: result,
            with: "$1"
        )
        result = replacing(
            pattern: #"<((?:https?|mailto):[^>\s]+)>"#,
            in: result,
            with: "$1",
            options: .caseInsensitive
        )
        return result
    }

    private static func replacing(
        pattern: String,
        in source: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

struct ActualNoteBody: Equatable, Sendable {
    let userBody: String
    let reservedLines: [String]

    init(storedNote: String?) {
        let normalized = (storedNote ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        reservedLines = lines.filter(Self.isReservedDirective)
        userBody = lines.filter { !Self.isReservedDirective($0) }.joined(separator: "\n")
    }

    var displayText: String? {
        let trimmed = userBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasUserNote: Bool {
        displayText != nil
    }

    func persistedNote(userBody: String) -> String? {
        let hasUserBody = !userBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasUserBody || !reservedLines.isEmpty else {
            return nil
        }
        guard hasUserBody else {
            return reservedLines.joined(separator: "\n")
        }
        guard !reservedLines.isEmpty else {
            return userBody
        }
        return userBody.hasSuffix("\n")
            ? userBody + reservedLines.joined(separator: "\n")
            : userBody + "\n" + reservedLines.joined(separator: "\n")
    }

    private static func isReservedDirective(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("#template")
            || normalized.hasPrefix("#goal")
            || normalized.hasPrefix("#cleanup")
    }
}
