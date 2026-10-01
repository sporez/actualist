import Foundation
import Testing
@testable import Actualist

struct ScheduleOccurrencePlannerTests {
    private let today = "2026-09-30"
    private let past = "2026-09-29"
    private let future = "2026-10-01"

    @Test func dueAutoPosts() {
        #expect(action(
            postsTransaction: true,
            isRecurring: false,
            nextDate: today,
            status: .due
        ) == .postScheduledDate)
    }

    @Test func missedAutoPosts() {
        #expect(action(
            postsTransaction: true,
            isRecurring: true,
            nextDate: past,
            status: .missed
        ) == .postScheduledDate)
    }

    @Test func upcomingDoesNotPost() {
        #expect(action(
            postsTransaction: true,
            isRecurring: true,
            nextDate: future,
            status: .upcoming
        ) == .stop)
    }

    @Test func scheduledDoesNotPost() {
        #expect(action(
            postsTransaction: true,
            isRecurring: false,
            nextDate: future,
            status: .scheduled
        ) == .stop)
    }

    @Test func completedDoesNotPost() {
        #expect(action(
            postsTransaction: true,
            isRecurring: false,
            nextDate: past,
            status: .completed
        ) == .stop)
    }

    @Test func paidTodayStops() {
        #expect(action(
            postsTransaction: true,
            isRecurring: true,
            nextDate: today,
            status: .paid
        ) == .stop)
    }

    @Test func paidRecurringPastDateAdvances() {
        #expect(action(
            postsTransaction: true,
            isRecurring: true,
            nextDate: past,
            status: .paid
        ) == .advanceRecurring)
    }

    @Test func paidRecurringFutureDateAdvances() {
        #expect(action(
            postsTransaction: true,
            isRecurring: true,
            nextDate: future,
            status: .paid
        ) == .advanceRecurring)
    }

    @Test func paidOneTimePastDateCompletes() {
        #expect(action(
            postsTransaction: true,
            isRecurring: false,
            nextDate: past,
            status: .paid
        ) == .completeOneTime)
    }

    @Test func paidOneTimeTodayStops() {
        #expect(action(
            postsTransaction: true,
            isRecurring: false,
            nextDate: today,
            status: .paid
        ) == .stop)
    }

    @Test func paidOneTimeFutureDateStops() {
        #expect(action(
            postsTransaction: true,
            isRecurring: false,
            nextDate: future,
            status: .paid
        ) == .stop)
    }

    @Test func closedAccountStops() {
        #expect(action(
            postsTransaction: true,
            isRecurring: false,
            nextDate: today,
            status: .due,
            accountAvailable: false
        ) == .stop)
    }

    @Test func emptyNextDateStops() {
        #expect(action(
            postsTransaction: true,
            isRecurring: true,
            nextDate: "",
            status: .missed
        ) == .stop)
    }

    @Test func postsTransactionFalseAndMissedStops() {
        #expect(action(
            postsTransaction: false,
            isRecurring: true,
            nextDate: past,
            status: .missed
        ) == .stop)
    }

    @Test func postsTransactionFalseAndPaidRecurringStillAdvances() {
        #expect(action(
            postsTransaction: false,
            isRecurring: true,
            nextDate: past,
            status: .paid
        ) == .advanceRecurring)
    }

    @Test func postsTransactionFalsePaidRecurringTodayStillAdvances() {
        #expect(action(
            postsTransaction: false,
            isRecurring: true,
            nextDate: today,
            status: .paid
        ) == .advanceRecurring)
    }

    private func action(
        postsTransaction: Bool,
        isRecurring: Bool,
        nextDate: String,
        status: ScheduleStatus,
        accountAvailable: Bool = true
    ) -> ScheduleAdvancementAction {
        ScheduleOccurrencePlanner.action(
            postsTransaction: postsTransaction,
            isRecurring: isRecurring,
            nextDate: nextDate,
            status: status,
            accountAvailable: accountAvailable,
            today: today
        )
    }
}
