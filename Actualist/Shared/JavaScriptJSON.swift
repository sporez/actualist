import Foundation

/// A JSON value as `JSON.parse` returns it.
enum JavaScriptJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JavaScriptJSONValue])
    case object([String: JavaScriptJSONValue])

    /// `JSON.parse(text)`, or `nil` where it throws a `SyntaxError`.
    /// ECMAScript's grammar exactly: only tab, LF, CR and space are
    /// whitespace (a leading BOM is an error), no trailing commas, and a
    /// repeated key keeps its last value. `JSONDecoder` differs on each.
    /// A `\u` escape for a lone surrogate, which a Swift string cannot hold,
    /// becomes U+FFFD.
    static func parse(_ text: String) -> JavaScriptJSONValue? {
        var parser = JavaScriptJSONParser(scalars: Array(text.unicodeScalars))
        return parser.parseText()
    }
}

private struct JavaScriptJSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    mutating func parseText() -> JavaScriptJSONValue? {
        skipWhitespace()
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return index == scalars.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while index < scalars.count, ["\t", "\n", "\r", " "].contains(scalars[index]) {
            index += 1
        }
    }

    private mutating func consume(_ literal: String) -> Bool {
        let expected = Array(literal.unicodeScalars)
        guard scalars[index...].starts(with: expected) else { return false }
        index += expected.count
        return true
    }

    private mutating func parseValue() -> JavaScriptJSONValue? {
        guard index < scalars.count else { return nil }
        switch scalars[index] {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map(JavaScriptJSONValue.string)
        case "t": return consume("true") ? .bool(true) : nil
        case "f": return consume("false") ? .bool(false) : nil
        case "n": return consume("null") ? .null : nil
        default: return parseNumber()
        }
    }

    private mutating func parseObject() -> JavaScriptJSONValue? {
        index += 1
        var members: [String: JavaScriptJSONValue] = [:]
        skipWhitespace()
        if index < scalars.count, scalars[index] == "}" {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < scalars.count, scalars[index] == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard index < scalars.count, scalars[index] == ":" else { return nil }
            index += 1
            skipWhitespace()
            guard let value = parseValue() else { return nil }
            members[key] = value
            skipWhitespace()
            guard index < scalars.count else { return nil }
            if scalars[index] == "," {
                index += 1
            } else if scalars[index] == "}" {
                index += 1
                return .object(members)
            } else {
                return nil
            }
        }
    }

    private mutating func parseArray() -> JavaScriptJSONValue? {
        index += 1
        var elements: [JavaScriptJSONValue] = []
        skipWhitespace()
        if index < scalars.count, scalars[index] == "]" {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            guard let value = parseValue() else { return nil }
            elements.append(value)
            skipWhitespace()
            guard index < scalars.count else { return nil }
            if scalars[index] == "," {
                index += 1
            } else if scalars[index] == "]" {
                index += 1
                return .array(elements)
            } else {
                return nil
            }
        }
    }

    private mutating func parseString() -> String? {
        index += 1
        var result = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "\"":
                return String(result)
            case "\\":
                guard index < scalars.count else { return nil }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "\"", "\\", "/": result.append(escape)
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    guard let unit = hexUnit() else { return nil }
                    if (0xD800...0xDBFF).contains(unit),
                       scalars[index...].starts(with: ["\\", "u"]) {
                        let saved = index
                        index += 2
                        if let low = hexUnit(), (0xDC00...0xDFFF).contains(low),
                           let pair = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) {
                            result.append(pair)
                            continue
                        }
                        index = saved
                    }
                    result.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                default:
                    return nil
                }
            default:
                // Control characters must be escaped.
                guard scalar.value >= 0x20 else { return nil }
                result.append(scalar)
            }
        }
        return nil
    }

    private mutating func hexUnit() -> UInt32? {
        guard index + 4 <= scalars.count else { return nil }
        var value: UInt32 = 0
        for scalar in scalars[index..<(index + 4)] {
            guard let digit = JavaScriptText.isDigit(scalar) ? scalar.value - 0x30 : hexLetter(scalar) else {
                return nil
            }
            value = value << 4 | digit
        }
        index += 4
        return value
    }

    private func hexLetter(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x41...0x46: return scalar.value - 0x41 + 10
        case 0x61...0x66: return scalar.value - 0x61 + 10
        default: return nil
        }
    }

    /// `-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`
    private mutating func parseNumber() -> JavaScriptJSONValue? {
        let start = index
        if index < scalars.count, scalars[index] == "-" { index += 1 }
        guard index < scalars.count, JavaScriptText.isDigit(scalars[index]) else { return nil }
        if scalars[index] == "0" {
            index += 1
        } else {
            while index < scalars.count, JavaScriptText.isDigit(scalars[index]) { index += 1 }
        }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            guard index < scalars.count, JavaScriptText.isDigit(scalars[index]) else { return nil }
            while index < scalars.count, JavaScriptText.isDigit(scalars[index]) { index += 1 }
        }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            guard index < scalars.count, JavaScriptText.isDigit(scalars[index]) else { return nil }
            while index < scalars.count, JavaScriptText.isDigit(scalars[index]) { index += 1 }
        }
        return .number(JavaScriptText.parseFloat(Array(scalars[start..<index])))
    }
}
