import Foundation

/// Registered budget-month divergences (`config/parity/known-divergences.json`). A replayed mismatch belongs to at
/// most one of them; `BudgetMonthOracleReplayTests` decides which ones each case must show.
enum BudgetMonthDivergence: String, CaseIterable {
    case op32 = "OP-32"
}

/// One case's mismatches split by divergence. Three kinds of row exist:
/// - A cell or outcome row is classified directly, by its path, its step label, and its values (`classify`).
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

    /// Values use the canonical form: strings are quoted (`"N:0"`), numbers are bare, and an absent side is
    /// `missing`. Only OP-32 remains: every other budget-month divergence was fixed.
    static func classify(_ mismatch: ReplayMismatch, stepLabels: [Int: String]) -> BudgetMonthDivergence? {
        // `step<n>.cell.<dataset>/<row>/<column>`
        let parts = mismatch.path.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "cell" else { return nil }
        let cell = parts[2].split(separator: "/", omittingEmptySubsequences: false)
        guard cell.count == 3 else { return nil }
        if cell[2] == "note", mismatch.actual == "missing", mismatch.expected.hasPrefix("\"S:- Reassigned") {
            return .op32
        }
        return nil
    }
}
