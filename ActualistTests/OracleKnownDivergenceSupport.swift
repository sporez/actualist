import Foundation

/// Replay mismatches split by whether a registered divergence accounts for them. Only `known`
/// may be wrapped in `withKnownIssue`; every other mismatch stays a strict failure.
struct KnownDivergenceSplit {
    let strict: [ReplayMismatch]
    let known: [ReplayMismatch]

    init(_ mismatches: [ReplayMismatch], knownPaths: Set<String>) {
        known = mismatches.filter { knownPaths.contains($0.path) }
        strict = mismatches.filter { !knownPaths.contains($0.path) }
    }
}
