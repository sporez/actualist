import Foundation
import Testing
@testable import Actualist

struct DeveloperUnlockTrackerTests {
    @Test func countdownAppearsForLastFiveTapsAndThenUnlocks() {
        var tracker = DeveloperUnlockTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<4 {
            #expect(tracker.recordTap(at: start.addingTimeInterval(Double(index))) == .hidden)
        }
        #expect(tracker.recordTap(at: start.addingTimeInterval(4)) == .countdown(remaining: 5))
        #expect(tracker.recordTap(at: start.addingTimeInterval(5)) == .countdown(remaining: 4))
        #expect(tracker.recordTap(at: start.addingTimeInterval(6)) == .countdown(remaining: 3))
        #expect(tracker.recordTap(at: start.addingTimeInterval(7)) == .countdown(remaining: 2))
        #expect(tracker.recordTap(at: start.addingTimeInterval(8)) == .countdown(remaining: 1))
        #expect(tracker.recordTap(at: start.addingTimeInterval(9)) == .unlocked)
    }

    @Test func inactivityResetsTapProgress() {
        var tracker = DeveloperUnlockTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<5 {
            _ = tracker.recordTap(at: start.addingTimeInterval(Double(index)))
        }
        let afterTimeout = tracker.recordTap(at: start.addingTimeInterval(30))

        #expect(afterTimeout == .hidden)
    }

    @Test func explicitResetClearsTapProgress() {
        var tracker = DeveloperUnlockTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            _ = tracker.recordTap(at: start.addingTimeInterval(Double(index)))
        }

        tracker.reset()

        #expect(tracker.recordTap(at: start.addingTimeInterval(6)) == .hidden)
    }
}
