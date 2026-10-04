import Foundation
import Synchronization

/// Compiled `matches` patterns for rule evaluation. A preview or a rule pass
/// evaluates the same condition against every transaction, so the pattern is
/// compiled once. Invalid patterns are cached as nil and keep never matching.
enum RuleRegexCache {
    private static let capacity = 128
    private struct State {
        var expressions: [String: NSRegularExpression?] = [:]
        var compileCount = 0
    }
    private static let state = Mutex(State())

    static func expression(for pattern: String) -> NSRegularExpression? {
        state.withLock { state in
            if let cached = state.expressions[pattern] { return cached }
            if state.expressions.count >= capacity { state.expressions.removeAll() }
            state.compileCount += 1
            let compiled = try? NSRegularExpression(pattern: pattern)
            state.expressions[pattern] = .some(compiled)
            return compiled
        }
    }

    /// Patterns compiled since launch; a test seam for the work count.
    static var compileCount: Int { state.withLock { $0.compileCount } }
}
