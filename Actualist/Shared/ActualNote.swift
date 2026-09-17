import Foundation
import SwiftUI

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
    struct Run: Equatable, Sendable {
        var text: String
        var isStrong: Bool
        var isEmphasis: Bool
    }

    let runs: [Run]

    var plainText: String {
        runs.map(\.text).joined()
    }

    init?(userBody: String?) {
        guard let userBody else {
            return nil
        }
        let source = userBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return nil
        }

        let displaySource = Self.displayMarkdownSource(from: source)
        runs = Self.parseRuns(from: displaySource) ?? [
            Run(text: source, isStrong: false, isEmphasis: false)
        ]
    }

    /// Apply fonts on the attributed runs. A view-level weighted `.font()` on
    /// `Text` flattens **bold** down to the same weight as surrounding text.
    @MainActor
    func displayText(baseFont: Font) -> Text {
        runs.reduce(Text("")) { result, run in
            var piece = Text(run.text).font(baseFont)
            if run.isStrong {
                piece = piece.bold()
            }
            if run.isEmphasis {
                piece = piece.italic()
            }
            return Text("\(result)\(piece)")
        }
    }

    /// Notes only need **strong** and *emphasis*. A local scanner avoids Swift
    /// `AttributedString` key paths, which are not Sendable under complete checking.
    private static func parseRuns(from source: String) -> [Run]? {
        var parsed: [Run] = []
        var current = ""
        var isStrong = false
        var isEmphasis = false
        let characters = Array(source)
        var index = 0

        func flush() {
            guard !current.isEmpty else {
                return
            }
            parsed.append(Run(text: current, isStrong: isStrong, isEmphasis: isEmphasis))
            current = ""
        }

        while index < characters.count {
            if index + 1 < characters.count,
               characters[index] == "*",
               characters[index + 1] == "*" {
                flush()
                isStrong.toggle()
                index += 2
                continue
            }
            if characters[index] == "*" {
                flush()
                isEmphasis.toggle()
                index += 1
                continue
            }
            current.append(characters[index])
            index += 1
        }
        flush()
        return parsed.isEmpty ? nil : parsed
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
