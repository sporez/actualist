import Foundation

/// loot-core `rankRules` / `computeScore`. Lower scores run first so more
/// specific exact-match rules (doubled scores) override contains/matches.
enum RuleRanking {
    private static let operationScores: [String: Int] = [
        "is": 10,
        "isNot": 10,
        "oneOf": 9,
        "notOneOf": 9,
        "isapprox": 5,
        "isbetween": 5,
        "gt": 1,
        "gte": 1,
        "lt": 1,
        "lte": 1,
        "contains": 0,
        "doesNotContain": 0,
        "matches": 0,
        "hasTags": 0,
        "onBudget": 0,
        "offBudget": 0
    ]

    private static let exactMatchOperations: Set<String> = [
        "is", "isNot", "isapprox", "oneOf", "notOneOf"
    ]

    static func rank(_ rules: [ManagedRule]) -> [ManagedRule] {
        let grouped = Dictionary(grouping: rules, by: stage(of:))
        return rankGroup(grouped[.pre, default: []])
            + rankGroup(grouped[.normal, default: []])
            + rankGroup(grouped[.post, default: []])
    }

    static func score(of rule: ManagedRule) -> Int {
        let conditions = rule.executionDraft()?.conditions ?? []
        let initial = conditions.reduce(0) { score, condition in
            guard let points = operationScores[condition.operation] else {
                return 0
            }
            return score + points
        }
        if conditions.allSatisfy({ exactMatchOperations.contains($0.operation) }) {
            return initial * 2
        }
        return initial
    }

    private static func rankGroup(_ rules: [ManagedRule]) -> [ManagedRule] {
        rules.sorted { lhs, rhs in
            let lhsScore = score(of: lhs)
            let rhsScore = score(of: rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.id < rhs.id
        }
    }

    private static func stage(of rule: ManagedRule) -> RuleStage {
        rule.draft?.stage
            ?? rule.rawStage.flatMap(RuleStage.init(rawValue:))
            ?? .normal
    }
}

extension Array where Element == ManagedRule {
    func rankedForExecution() -> [ManagedRule] {
        RuleRanking.rank(self)
    }
}
