import Foundation

/// Registered budget-month divergences (`config/parity/known-divergences.json`). A replayed mismatch belongs to at
/// most one of them; `BudgetMonthOracleReplayTests` decides which ones each case must show.
enum BudgetMonthDivergence: String, CaseIterable {
    case op26 = "OP-26"
    case op27 = "OP-27"
    case op28 = "OP-28"
    case op29 = "OP-29"
    case op30 = "OP-30"
    case op31 = "OP-31"
    case op32 = "OP-32"
    case op33 = "OP-33"
    case op34 = "OP-34"
    /// A field comparison, not a cascade cause: its rows never anchor other divergences' cascades.
    case op35 = "OP-35"
}

/// One case's mismatches split by divergence. Three kinds of row exist:
/// - A cell or outcome row is classified directly, by its path, its step label, and its values (`classify`).
///   A `last-month-overspent` field row is also classified directly (OP-35), but it does not anchor cascades.
/// - A summary or cascade row at or after the case's first directly classified step (the anchor) takes that
///   anchor's divergence. This is co-occurrence within the case, not a trace of each row. A `final.` row is at or
///   after every step.
/// - Everything else stays `unclassified` and must be empty: rows before the anchor, `before.` rows, rows in a case
///   with no anchor, and every `.consistency.` row (Actualist's own identities are never attributed).
struct BudgetMonthDivergenceSplit {
    private(set) var byDivergence: [BudgetMonthDivergence: [ReplayMismatch]] = [:]
    private(set) var unclassified: [ReplayMismatch] = []

    init(_ mismatches: [ReplayMismatch], stepLabels: [Int: String]) {
        var classified: [(step: Int, divergence: BudgetMonthDivergence, mismatch: ReplayMismatch)] = []
        var cascades: [(step: Int, mismatch: ReplayMismatch)] = []
        for mismatch in mismatches {
            if mismatch.path.contains(".consistency.") {
                unclassified.append(mismatch)
            } else if let divergence = Self.classify(mismatch, stepLabels: stepLabels) {
                classified.append((Self.stepIndex(mismatch.path), divergence, mismatch))
            } else {
                cascades.append((Self.stepIndex(mismatch.path), mismatch))
            }
        }
        let anchor = classified
            .filter { $0.divergence != .op35 }
            .min { ($0.step, $0.divergence.rawValue) < ($1.step, $1.divergence.rawValue) }
        for row in classified {
            byDivergence[row.divergence, default: []].append(row.mismatch)
        }
        for row in cascades {
            guard let anchor, row.step >= anchor.step else {
                unclassified.append(row.mismatch)
                continue
            }
            byDivergence[anchor.divergence, default: []].append(row.mismatch)
        }
    }

    func mismatches(for divergence: BudgetMonthDivergence) -> [ReplayMismatch] {
        byDivergence[divergence] ?? []
    }

    /// The step index named by a `step<n>.` prefix; `Int.max` for `final.`; `-1` for `before.` and any other path,
    /// which can never be at or after an anchor.
    static func stepIndex(_ path: String) -> Int {
        if path.hasPrefix("final.") {
            return Int.max
        }
        guard path.hasPrefix("step"), let dot = path.firstIndex(of: ".") else {
            return -1
        }
        return Int(path[path.index(path.startIndex, offsetBy: 4)..<dot]) ?? -1
    }

    /// First match wins. Values use the canonical form: strings are quoted (`"N:0"`), numbers are bare, and an
    /// absent side is `missing`.
    static func classify(_ mismatch: ReplayMismatch, stepLabels: [Int: String]) -> BudgetMonthDivergence? {
        let path = mismatch.path
        let step = stepIndex(path)
        let absent = mismatch.actual == "missing"
        let missingExpected = mismatch.expected == "missing"

        if path.hasSuffix(".outcome") {
            return stepLabels[step] == "hold" ? .op34 : nil
        }
        if path.hasSuffix(".last-month-overspent") {
            return .op35
        }
        // `step<n>.cell.<dataset>/<row>/<column>`
        let parts = path.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "cell" else { return nil }
        let cell = parts[2].split(separator: "/", omittingEmptySubsequences: false)
        guard cell.count == 3 else { return nil }
        let dataset = String(cell[0])
        let row = String(cell[1])
        let column = String(cell[2])
        let label = stepLabels[step]

        if dataset == "zero_budgets", row.contains("-to-budget"), absent { return .op27 }
        if dataset == "zero_budget_months", column == "buffered", absent, label == "reset" { return .op31 }
        if column == "note", absent, mismatch.expected.hasPrefix("\"S:- Reassigned") { return .op32 }
        if column == "month", mismatch.expected.hasPrefix("\"S:"), mismatch.actual.hasPrefix("\"N:") { return .op30 }
        if label == "carryover", absent, dataset == "zero_budgets" || dataset == "reflect_budgets" { return .op33 }
        if label == "hold", absent { return .op34 }
        if column == "carryover", missingExpected, mismatch.actual.hasPrefix("\"N:") { return .op28 }
        if column == "category" || column == "month", missingExpected, !absent { return .op29 }
        if dataset == "zero_budgets", column == "amount", label == "cover" || label == "transfer-available",
           !row.contains("-to-budget") {
            return .op26
        }
        return nil
    }
}
