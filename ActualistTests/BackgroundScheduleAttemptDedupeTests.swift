import Foundation
import Testing
@testable import Actualist

/// Phase 5.10: an unchanged schedule is not recorded again. The recorder's
/// attempt count is the work count (each record rewrites the settings JSON).
@MainActor
struct BackgroundScheduleAttemptDedupeTests {
    private func makeAppState() throws -> AppState {
        let suite = "BackgroundScheduleAttemptDedupeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppState(settingsStore: AppSettingsStore(defaults: defaults))
    }

    @Test func repeatedIdenticalSchedulingRecordsOnce() throws {
        let state = try makeAppState()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<10 {
            state.recordBackgroundRefreshScheduleAttempt(
                succeeded: true,
                earliestBeginDate: base.addingTimeInterval(Double(index) * 30),
                message: "Scheduled background refresh"
            )
        }
        #expect(state.settings.backgroundRefreshDebug.totalScheduleAttemptCount == 1)
        for _ in 0..<5 {
            state.recordBackgroundRefreshScheduleAttempt(
                succeeded: false, earliestBeginDate: nil, message: "Skipped: alerts and bank sync disabled")
        }
        #expect(state.settings.backgroundRefreshDebug.totalScheduleAttemptCount == 2)
    }

    @Test func aChangedOutcomeMessageOrScheduleIsRecorded() throws {
        let state = try makeAppState()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let steps: [(Bool, Date?, String)] = [
            (true, base, "Scheduled background refresh"),
            (false, base, "Scheduled background refresh"),
            (false, base, "Schedule failed: denied"),
            (false, nil, "Schedule failed: denied"),
            (false, base.addingTimeInterval(3_600), "Schedule failed: denied"),
            (false, base.addingTimeInterval(3_700), "Schedule failed: denied"),
        ]
        for (succeeded, date, message) in steps {
            state.recordBackgroundRefreshScheduleAttempt(succeeded: succeeded, earliestBeginDate: date, message: message)
        }
        // The last step is within tolerance of the one before it.
        #expect(state.settings.backgroundRefreshDebug.totalScheduleAttemptCount == 5)
        #expect(state.settings.backgroundRefreshDebug.recentScheduleAttempts.count == 5)
    }
}
