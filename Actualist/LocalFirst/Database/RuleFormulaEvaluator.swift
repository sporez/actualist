import Foundation

/// Focused Actual 26.8.1 split-amount formula evaluator.
///
/// Ports the numeric subset used by `Action.executeFormulaSync` for
/// `set-split-amount` method `formula`: arithmetic, named transaction fields,
/// `INTEGER_TO_AMOUNT`, and `BALANCE_OF`. Unsupported HyperFormula surfaces
/// fail closed.
enum RuleFormulaValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

struct RuleFormulaContext: Equatable, Sendable {
    var fields: [String: RuleFormulaValue]
    var balanceOfPrefetch: [String: Int]
    var today: String

    static let empty = RuleFormulaContext(fields: [:], balanceOfPrefetch: [:], today: "")
}

enum RuleFormulaEvaluator {
    enum EvaluationError: Error, Equatable {
        case missingEqualsPrefix
        case unsupported
        case typeMismatch
        case divideByZero
        case outOfRange
    }

    static func evaluate(_ formula: String, context: RuleFormulaContext) throws -> RuleFormulaValue {
        var parser = Parser(formula: formula, context: context)
        let value = try parser.parseFormula()
        try parser.expectEnd()
        if case .number(let number) = value {
            return .number(Double(try amountToInteger(number)))
        }
        return value
    }

    /// Actual `amountToInteger(Math.round(value * 100) / 100)` at 2 decimals.
    static func amountToInteger(_ value: Double) throws -> Int {
        try javascriptRound(javascriptRoundToDouble(value * 100) / 100 * 100)
    }

    /// JavaScript `Math.round`: ties toward +∞.
    static func javascriptRound(_ value: Double) throws -> Int {
        guard value.isFinite else { throw EvaluationError.outOfRange }
        let rounded = floor(value + 0.5)
        guard rounded >= Double(Int.min), rounded <= Double(Int.max) else {
            throw EvaluationError.outOfRange
        }
        return Int(rounded)
    }

    static func extractBalanceOfLiterals(_ formula: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"BALANCE_OF\s*\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(formula.startIndex..., in: formula)
        var seen = Set<String>()
        var literals: [String] = []
        for match in expression.matches(in: formula, range: range) {
            guard let inner = Range(match.range(at: 1), in: formula) else { continue }
            let decoded = decodeBalanceOfQuotedLiteral(String(formula[inner]))
            if seen.insert(decoded).inserted {
                literals.append(decoded)
            }
        }
        return literals
    }

    static func decodeBalanceOfQuotedLiteral(_ inner: String) -> String {
        inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func javascriptRoundToDouble(_ value: Double) throws -> Double {
        Double(try javascriptRound(value))
    }
}

private struct Parser {
    private let context: RuleFormulaContext
    private let scalars: [Character]
    private var index = 0

    init(formula: String, context: RuleFormulaContext) {
        self.context = context
        self.scalars = Array(formula)
    }

    mutating func parseFormula() throws -> RuleFormulaValue {
        skipWhitespace()
        guard peek() == "=" else { throw RuleFormulaEvaluator.EvaluationError.missingEqualsPrefix }
        advance()
        return try parseExpression()
    }

    mutating func expectEnd() throws {
        skipWhitespace()
        guard index >= scalars.count else { throw RuleFormulaEvaluator.EvaluationError.unsupported }
    }

    private mutating func parseExpression() throws -> RuleFormulaValue {
        var value = try parseTerm()
        while true {
            skipWhitespace()
            guard let op = peek(), op == "+" || op == "-" else { return value }
            advance()
            let rhs = try parseTerm()
            value = try binary(value, rhs, op)
        }
    }

    private mutating func parseTerm() throws -> RuleFormulaValue {
        var value = try parseUnary()
        while true {
            skipWhitespace()
            guard let op = peek(), op == "*" || op == "/" else { return value }
            advance()
            let rhs = try parseUnary()
            value = try binary(value, rhs, op)
        }
    }

    private mutating func parseUnary() throws -> RuleFormulaValue {
        skipWhitespace()
        if peek() == "-" {
            advance()
            guard let number = try parseUnary().number else {
                throw RuleFormulaEvaluator.EvaluationError.typeMismatch
            }
            return .number(-number)
        }
        if peek() == "+" {
            advance()
            return try parseUnary()
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> RuleFormulaValue {
        skipWhitespace()
        guard let char = peek() else { throw RuleFormulaEvaluator.EvaluationError.unsupported }
        if char == "(" {
            advance()
            let value = try parseExpression()
            skipWhitespace()
            guard peek() == ")" else { throw RuleFormulaEvaluator.EvaluationError.unsupported }
            advance()
            return value
        }
        if char == "\"" {
            return .string(try parseString())
        }
        if char.isNumber || char == "." {
            return .number(try parseNumber())
        }
        if char.isLetter || char == "_" {
            let name = parseIdentifier()
            skipWhitespace()
            if peek() == "(" {
                return try parseFunction(name)
            }
            return lookup(name)
        }
        throw RuleFormulaEvaluator.EvaluationError.unsupported
    }

    private mutating func parseFunction(_ rawName: String) throws -> RuleFormulaValue {
        advance()
        var arguments: [RuleFormulaValue] = []
        skipWhitespace()
        if peek() != ")" {
            arguments.append(try parseExpression())
            while true {
                skipWhitespace()
                guard peek() == "," else { break }
                advance()
                arguments.append(try parseExpression())
            }
        }
        skipWhitespace()
        guard peek() == ")" else { throw RuleFormulaEvaluator.EvaluationError.unsupported }
        advance()
        return try evaluateFunction(rawName, arguments: arguments)
    }

    private func evaluateFunction(_ rawName: String, arguments: [RuleFormulaValue]) throws -> RuleFormulaValue {
        switch rawName.uppercased() {
        case "BALANCE_OF":
            guard arguments.count == 1, case .string(let key) = arguments[0] else {
                throw RuleFormulaEvaluator.EvaluationError.typeMismatch
            }
            return .number(Double(context.balanceOfPrefetch[key] ?? 0))
        case "INTEGER_TO_AMOUNT":
            guard let integer = arguments.first?.number, (1...2).contains(arguments.count) else {
                throw RuleFormulaEvaluator.EvaluationError.typeMismatch
            }
            let decimals = arguments.count == 2 ? arguments[1].number ?? 2 : 2
            guard decimals.isFinite, (0...15).contains(decimals) else {
                throw RuleFormulaEvaluator.EvaluationError.outOfRange
            }
            return .number(integer / pow(10, decimals))
        default:
            throw RuleFormulaEvaluator.EvaluationError.unsupported
        }
    }

    private func lookup(_ name: String) -> RuleFormulaValue {
        if name == "today" { return .string(context.today) }
        return context.fields[name] ?? .string("")
    }

    private func binary(_ lhs: RuleFormulaValue, _ rhs: RuleFormulaValue, _ op: Character) throws -> RuleFormulaValue {
        guard let left = lhs.number, let right = rhs.number else {
            throw RuleFormulaEvaluator.EvaluationError.typeMismatch
        }
        switch op {
        case "+": return .number(left + right)
        case "-": return .number(left - right)
        case "*": return .number(left * right)
        case "/":
            guard right != 0 else { throw RuleFormulaEvaluator.EvaluationError.divideByZero }
            return .number(left / right)
        default:
            throw RuleFormulaEvaluator.EvaluationError.unsupported
        }
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        while let char = peek(), char.isNumber { advance() }
        if peek() == "." {
            advance()
            while let char = peek(), char.isNumber { advance() }
        }
        let text = String(scalars[start..<index])
        guard let value = Double(text), value.isFinite else {
            throw RuleFormulaEvaluator.EvaluationError.unsupported
        }
        return value
    }

    private mutating func parseString() throws -> String {
        advance()
        var text = ""
        while let char = peek() {
            advance()
            if char == "\"" { return text }
            if char == "\\" {
                guard let escaped = peek() else { throw RuleFormulaEvaluator.EvaluationError.unsupported }
                advance()
                text.append(escaped)
            } else {
                text.append(char)
            }
        }
        throw RuleFormulaEvaluator.EvaluationError.unsupported
    }

    private mutating func parseIdentifier() -> String {
        let start = index
        while let char = peek(), char.isLetter || char.isNumber || char == "_" {
            advance()
        }
        return String(scalars[start..<index])
    }

    private mutating func skipWhitespace() {
        while let char = peek(), char.isWhitespace { advance() }
    }

    private func peek() -> Character? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() {
        index += 1
    }
}
