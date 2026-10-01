import Foundation
import Testing
@testable import Actualist

@Suite("Schedule presentation")
struct SchedulePresentationTests {
    @Test func currentDayUsesLocalGregorianDateAcrossUTCAndYearBoundaries() throws {
        let midnightUTC = try #require(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        let west = try #require(TimeZone(secondsFromGMT: -8 * 60 * 60))
        let east = try #require(TimeZone(secondsFromGMT: 14 * 60 * 60))
        #expect(SchedulesViewContext.currentDay(now: midnightUTC, timeZone: west) == "2025-12-31")
        #expect(SchedulesViewContext.currentDay(now: midnightUTC, timeZone: east) == "2026-01-01")
        #expect(SchedulesViewContext.currentDay(
            now: midnightUTC.addingTimeInterval(12 * 60 * 60), timeZone: east
        ) == "2026-01-02")
    }

    @Test func loadIdentityRefreshInputsDoNotChangeBudgetSessionIdentity() {
        let context = context()
        let initial = SchedulesLoadIdentity(
            context: context,
            refreshRevision: 10,
            manualRefreshGeneration: 0
        )
        let revisionRefresh = SchedulesLoadIdentity(
            context: context,
            refreshRevision: 11,
            manualRefreshGeneration: 0
        )
        let manualRefresh = SchedulesLoadIdentity(
            context: context,
            refreshRevision: 10,
            manualRefreshGeneration: 1
        )

        #expect(initial != revisionRefresh)
        #expect(initial != manualRefresh)
        #expect(initial.context.identity == revisionRefresh.context.identity)
        #expect(initial.context.identity == manualRefresh.context.identity)
    }

    @Test func privacyProjectionMasksEverySensitiveSearchField() {
        let schedule = ScheduleSummary(
            id: "rent",
            name: "Secret Rent",
            amount: .exact(-12_500),
            account: ScheduleAccountReference(
                id: "checking",
                name: "Private Checking",
                availability: .available
            ),
            payee: SchedulePayeeReference(
                id: "landlord",
                name: "Private Landlord",
                isMissing: false
            ),
            effectiveNextDate: "2026-09-28",
            status: .upcoming,
            postsTransaction: false,
            sortOrder: nil,
            unsupportedReasons: []
        )

        let row = SchedulePresentation.row(schedule, context: context(privacyEnabled: true))

        #expect(row.title.hasPrefix("Sample Schedule "))
        #expect(!row.searchableText.contains("Secret Rent"))
        #expect(!row.searchableText.contains("Private Checking"))
        #expect(!row.searchableText.contains("Private Landlord"))
        #expect(!row.searchableText.contains(BudgetCurrency.usd.formatted(-12_500)))
        #expect(row.searchableText.contains(row.amountText))
    }

    @Test func detailShowsStoredStateClosedAccountAndUnsupportedReasons() {
        let detail = scheduleDetail(
            account: ScheduleAccountReference(
                id: "closed-card",
                name: "Closed Card",
                availability: .closed
            ),
            payee: SchedulePayeeReference(id: nil, name: nil, isMissing: false),
            status: .missed,
            completed: false,
            postsTransaction: true,
            unsupportedReasons: [.unsupportedDate, .corruptRuleLinkage]
        )

        let presentation = SchedulePresentation.detail(
            detail,
            defaultUpcomingLength: "7",
            context: context()
        )

        #expect(presentation.statusText == "Missed")
        #expect(presentation.statusTone == .danger)
        #expect(presentation.stateText == "Active")
        #expect(presentation.accountText == "Closed Card (Closed)")
        #expect(presentation.accountAvailability == .closed)
        #expect(presentation.payeeText == "No payee")
        #expect(presentation.automaticPostingText == "Enabled")
        #expect(presentation.upcomingWindowText == "7 days (Budget default)")
        #expect(presentation.unsupportedMessages == [
            ScheduleUnsupportedReason.unsupportedDate.message,
            ScheduleUnsupportedReason.corruptRuleLinkage.message
        ])
    }

    @Test func rowLabelsClosedAndMissingReferencesWithoutHidingTheSchedule() {
        let schedule = ScheduleSummary(
            id: "utilities",
            name: "Utilities",
            amount: .unavailable,
            account: ScheduleAccountReference(
                id: "closed-card",
                name: "Closed Card",
                availability: .closed
            ),
            payee: SchedulePayeeReference(
                id: "missing-payee",
                name: nil,
                isMissing: true
            ),
            effectiveNextDate: nil,
            status: .scheduled,
            postsTransaction: false,
            sortOrder: nil,
            unsupportedReasons: [.missingAmount, .missingNextDate]
        )

        let row = SchedulePresentation.row(schedule, context: context())

        #expect(row.referenceText == "Unavailable payee • Closed Card (Closed)")
        #expect(row.amountText == "Amount unavailable")
        #expect(row.dateText == "Date unavailable")
        #expect(row.limitationText == "Some schedule options are unavailable")
    }

    @Test func detailKeepsMissingReferencesVisibleAndCompletedFlagExplicit() {
        let detail = scheduleDetail(
            account: ScheduleAccountReference(
                id: "missing-account",
                name: nil,
                availability: .missing
            ),
            payee: SchedulePayeeReference(
                id: "missing-payee",
                name: nil,
                isMissing: true
            ),
            status: .completed,
            completed: true,
            postsTransaction: false,
            unsupportedReasons: [.missingRule]
        )

        let presentation = SchedulePresentation.detail(
            detail,
            defaultUpcomingLength: "oneMonth",
            context: context()
        )

        #expect(presentation.stateText == "Completed")
        #expect(presentation.accountText == "Unavailable account")
        #expect(presentation.accountAvailability == .missing)
        #expect(presentation.payeeText == "Unavailable payee")
        #expect(presentation.payeeIsMissing)
        #expect(presentation.automaticPostingText == "Disabled")
        #expect(presentation.upcomingWindowText == "One month (Budget default)")
    }

    @Test func recurrenceDescriptionPreservesMonthlyPatterns() throws {
        let recurrence = try ActualScheduleRecurrence(
            startDayID: "2026-01-01",
            frequency: .monthly,
            patterns: [
                .dayOfMonth(15),
                .weekday(.monday, ordinal: -1)
            ]
        )

        #expect(
            SchedulePresentation.recurrenceLabel(.recurring(recurrence, operation: "is"))
                == "Every month • day 15, last Monday"
        )
    }

    private func context(
        privacyEnabled: Bool = false
    ) -> SchedulesViewContext {
        SchedulesViewContext(
            identity: SchedulesBudgetIdentity(
                budgetID: "budget",
                sessionGeneration: 1
            ),
            currency: .usd,
            isPrivacyModeEnabled: privacyEnabled,
            asOfDayID: "2026-09-27"
        )
    }

    private func scheduleDetail(
        account: ScheduleAccountReference,
        payee: SchedulePayeeReference,
        status: ScheduleStatus,
        completed: Bool,
        postsTransaction: Bool,
        unsupportedReasons: [ScheduleUnsupportedReason]
    ) -> ScheduleDetail {
        ScheduleDetail(
            id: "schedule",
            ruleID: "rule",
            name: "Schedule",
            amount: .approximate(-4_500),
            dateRule: .oneTime(dayID: "2026-09-28", operation: "is"),
            account: account,
            payee: payee,
            effectiveNextDate: "2026-09-28",
            status: status,
            completed: completed,
            postsTransaction: postsTransaction,
            customUpcomingLength: nil,
            sortOrder: nil,
            rawConditionsJSON: nil,
            rawActionsJSON: nil,
            capabilities: ScheduleMutationCapabilities(
                canRead: true, canEditMetadata: false, canEditAccount: false,
                canEditPayee: false, canEditAmount: false, canEditDate: false,
                canSkip: false, canComplete: false, canDelete: false, canPost: false
            ),
            unsupportedReasons: unsupportedReasons,
            occurrenceIdentity: ScheduleOccurrenceIdentity(
                scheduleID: "schedule",
                nextDateRowID: "next-date",
                effectiveNextDate: "2026-09-28",
                localNextDateTimestamp: "1",
                baseNextDateTimestamp: "1"
            )
        )
    }
}
