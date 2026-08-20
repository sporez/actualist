import Foundation

enum DeveloperUnlockTapOutcome: Equatable, Sendable {
    case hidden
    case countdown(remaining: Int)
    case unlocked
}

struct DeveloperUnlockTracker: Equatable, Sendable {
    private static let requiredTapCount = 10
    private static let visibleCountdownThreshold = 5
    private static let resetInterval: TimeInterval = 20

    private var tapCount = 0
    private var lastTapDate: Date?

    mutating func recordTap(at date: Date) -> DeveloperUnlockTapOutcome {
        if let lastTapDate,
           date.timeIntervalSince(lastTapDate) > Self.resetInterval {
            tapCount = 0
        }

        lastTapDate = date
        tapCount += 1
        let remaining = max(0, Self.requiredTapCount - tapCount)
        if remaining == 0 {
            return .unlocked
        }
        guard remaining <= Self.visibleCountdownThreshold else {
            return .hidden
        }
        return .countdown(remaining: remaining)
    }

    mutating func reset() {
        tapCount = 0
        lastTapDate = nil
    }
}
