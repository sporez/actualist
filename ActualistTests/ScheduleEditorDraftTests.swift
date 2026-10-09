import Foundation
import Testing
@testable import Actualist

@Suite("Schedule editor draft")
struct ScheduleEditorDraftTests {
    @Test func payeePickerProjectionMarksTransfersAndTitlesSelection() {
        let choices = ScheduleEditorChoices.project(TransactionEditorOptions(
            accounts: [ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false)],
            categories: [],
            categoryGroups: [],
            payees: [
                ActualPayee(id: "coffee", name: "Coffee Shop", category: nil, transferAccount: nil),
                ActualPayee(id: "to-savings", name: "", category: nil, transferAccount: "savings")
            ]
        ))

        #expect(choices.payeePickerItems.map(\.id) == ["coffee", "to-savings"])
        #expect(choices.payeePickerItems.map(\.isTransfer) == [false, true])
        #expect(choices.payeeTitle(for: nil) == "No payee")
        #expect(choices.payeeTitle(for: "to-savings") == "Savings")
        #expect(choices.payeeTitle(for: "deleted") == "Current payee (unavailable)")
    }

    @Test func canonicalPayeeChoiceDoesNotRewriteAnUntouchedLegacyAlias() throws {
        let reviewed = review(payeeID: "legacy-coffee")
        let detail = detail(payeeID: "coffee")
        let choices = ScheduleEditorChoices.project(TransactionEditorOptions(
            accounts: [ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)],
            categories: [],
            categoryGroups: [],
            payees: [ActualPayee(id: "coffee", name: "Coffee Shop", category: nil, transferAccount: nil)]
        ))
        var draft = ScheduleEditorDraft(review: reviewed, detail: detail, currency: .usd)

        #expect(choices.payees.map(\.id) == ["coffee"])
        #expect(draft.payeeID == "coffee")
        #expect(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US"))?.payeeMappingID == .unchanged)

        draft.name = "Updated name"
        draft.nameWasChanged = true
        let metadataOnly = try #require(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US")))
        #expect(metadataOnly.name == .set("Updated name"))
        #expect(metadataOnly.payeeMappingID == .unchanged)
        #expect(metadataOnly.amount == .unchanged)
        #expect(metadataOnly.dateRule == .unchanged)

        draft.payeeWasChanged = true
        #expect(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US"))?.payeeMappingID == .unchanged)

        draft.payeeID = "another-payee"
        let changedPayee = try #require(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US")))
        #expect(changedPayee.payeeMappingID == .set("another-payee"))

        draft.payeeID = "coffee"
        #expect(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US"))?.payeeMappingID == .unchanged)
    }

    @Test func unsupportedEditorFieldsCannotBeReviewedOrIncludedAsCommands() throws {
        let reviewed = review(payeeID: "coffee")
        let detail = detail(
            payeeID: "coffee",
            capabilities: ScheduleMutationCapabilities(
                canRead: true,
                canEditMetadata: true,
                canEditAccount: false,
                canEditPayee: false,
                canEditAmount: false,
                canEditDate: false,
                canSkip: false,
                canComplete: false,
                canDelete: true,
                canPost: false
            )
        )
        var draft = ScheduleEditorDraft(review: reviewed, detail: detail, currency: .usd)
        draft.name = "Rename"
        draft.nameWasChanged = true
        draft.amountText = "45.00"
        draft.amountSign = .deposit
        draft.amountWasChanged = true
        draft.dateWasChanged = true

        #expect(!draft.canSave(
            isCreate: false,
            capabilities: detail.capabilities,
            currency: .usd,
            locale: Locale(identifier: "en_US")
        ))
        draft.amountWasChanged = false
        draft.dateWasChanged = false
        let metadata = try #require(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US")))
        #expect(metadata.name == .set("Rename"))
        #expect(metadata.accountID == .unchanged)
        #expect(metadata.payeeMappingID == .unchanged)
        #expect(metadata.amount == .unchanged)
        #expect(metadata.dateRule == .unchanged)
    }

    @Test func amountDraftUsesBudgetCurrencyScaleAndValidatesRanges() {
        var draft = ScheduleEditorDraft(todayDayID: "2026-09-28")
        draft.amountMode = .range
        draft.amountSign = .deposit
        draft.amountText = "12.34"
        draft.rangeEndText = "24.68"

        #expect(draft.amountDraft(currency: .usd, locale: Locale(identifier: "en_US")) == .range(lower: 1_234, upper: 2_468))
        #expect(draft.amountDraft(currency: .jpy, locale: Locale(identifier: "en_US")) == .range(lower: 12, upper: 25))

        draft.rangeEndText = "10.00"
        #expect(draft.amountDraft(currency: .usd, locale: Locale(identifier: "en_US")) == nil)
    }

    @Test func editDraftsRetainCurrencyPrecisionWhenDisplayHidesFractions() {
        let hiddenFractionUSD = BudgetCurrency(code: "USD", decimalPlaces: 2, hideFraction: true)
        let locale = Locale(identifier: "en_US")

        let positiveExact = ScheduleEditorDraft(
            review: review(payeeID: "coffee", amountValue: "12345"),
            detail: detail(payeeID: "coffee"),
            currency: hiddenFractionUSD
        )
        #expect(positiveExact.amountText == "123.45")
        #expect(positiveExact.amountDraft(currency: hiddenFractionUSD, locale: locale) == .exact(12_345))

        let negativeExact = ScheduleEditorDraft(
            review: review(payeeID: "coffee", amountValue: "-12345"),
            detail: detail(payeeID: "coffee"),
            currency: hiddenFractionUSD
        )
        #expect(negativeExact.amountText == "123.45")
        #expect(negativeExact.amountSign == .spend)
        #expect(negativeExact.amountDraft(currency: hiddenFractionUSD, locale: locale) == .exact(-12_345))

        let negativeApproximate = ScheduleEditorDraft(
            review: review(payeeID: "coffee", amountValue: "-12345", amountOperation: "isapprox"),
            detail: detail(payeeID: "coffee"),
            currency: hiddenFractionUSD
        )
        #expect(negativeApproximate.amountText == "123.45")
        #expect(negativeApproximate.amountSign == .spend)
        #expect(negativeApproximate.amountDraft(currency: hiddenFractionUSD, locale: locale) == .approximate(-12_345))

        let positiveRange = ScheduleEditorDraft(
            review: review(payeeID: "coffee", amountValue: #"{"num1":12345,"num2":23456}"#, amountOperation: "isbetween"),
            detail: detail(payeeID: "coffee"),
            currency: hiddenFractionUSD
        )
        #expect(positiveRange.amountSign == .deposit)
        #expect(positiveRange.amountText == "123.45")
        #expect(positiveRange.rangeEndText == "234.56")
        #expect(positiveRange.amountDraft(currency: hiddenFractionUSD, locale: locale) == .range(lower: 12_345, upper: 23_456))

        let negativeRange = ScheduleEditorDraft(
            review: review(payeeID: "coffee", amountValue: #"{"num1":-23456,"num2":-12345}"#, amountOperation: "isbetween"),
            detail: detail(payeeID: "coffee"),
            currency: hiddenFractionUSD
        )
        #expect(negativeRange.amountSign == .spend)
        #expect(negativeRange.amountText == "123.45")
        #expect(negativeRange.rangeEndText == "234.56")
        #expect(negativeRange.amountDraft(currency: hiddenFractionUSD, locale: locale) == .range(lower: -23_456, upper: -12_345))

        let wholeCurrency = ScheduleEditorDraft(
            review: review(payeeID: "coffee", amountValue: "12345"),
            detail: detail(payeeID: "coffee"),
            currency: .jpy
        )
        #expect(wholeCurrency.amountText == "12345")
        #expect(wholeCurrency.amountDraft(currency: .jpy, locale: locale) == .exact(12_345))
    }

    @Test func newScheduleDefaultsToSpendAndAppliesTheSignInEveryAmountMode() {
        let locale = Locale(identifier: "en_US")
        var draft = ScheduleEditorDraft(todayDayID: "2026-09-28")
        #expect(draft.amountSign == .spend)
        draft.amountText = "45.00"

        #expect(draft.amountDraft(currency: .usd, locale: locale) == .exact(-4_500))
        draft.amountMode = .approximate
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .approximate(-4_500))
        draft.amountMode = .range
        draft.rangeEndText = "60.00"
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .range(lower: -6_000, upper: -4_500))

        draft.amountSign = .deposit
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .range(lower: 4_500, upper: 6_000))
        draft.amountMode = .exact
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .exact(4_500))
        draft.amountMode = .approximate
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .approximate(4_500))
    }

    @Test func typedMinusDoesNotFlipTheChosenSignAndZeroStaysZero() {
        let locale = Locale(identifier: "en_US")
        var draft = ScheduleEditorDraft(todayDayID: "2026-09-28")
        draft.amountText = "-45.00"
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .exact(-4_500))
        draft.amountSign = .deposit
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .exact(4_500))

        draft.amountText = "0"
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .exact(0))
        draft.amountSign = .spend
        #expect(draft.amountDraft(currency: .usd, locale: locale) == .exact(0))
    }

    @Test func createDefinitionCarriesTheSignedAmountForExpenseAndDeposit() throws {
        let locale = Locale(identifier: "en_US")
        var draft = ScheduleEditorDraft(todayDayID: "2026-09-28")
        draft.accountID = "checking"
        draft.amountText = "12.50"

        #expect(try #require(draft.createDefinition(currency: .usd, locale: locale)).amount == .exact(-1_250))
        draft.amountSign = .deposit
        #expect(try #require(draft.createDefinition(currency: .usd, locale: locale)).amount == .exact(1_250))
    }

    @Test func editingStoredNegativeAmountShowsSpendAndOnlyAChangeProducesACommand() throws {
        let locale = Locale(identifier: "en_US")
        let reviewed = review(payeeID: "coffee", amountValue: "-12345")
        let detail = detail(payeeID: "coffee")
        var draft = ScheduleEditorDraft(review: reviewed, detail: detail, currency: .usd)
        #expect(draft.amountSign == .spend)
        #expect(draft.amountText == "123.45")

        draft.amountWasChanged = true
        #expect(try #require(draft.editFields(currency: .usd, locale: locale)).amount == .unchanged)

        draft.amountSign = .deposit
        #expect(try #require(draft.editFields(currency: .usd, locale: locale)).amount == .set(.exact(12_345)))
    }

    @Test func rangeThatCrossesZeroIsLeftUnchangedUntilTheUserEntersAnAmount() throws {
        let locale = Locale(identifier: "en_US")
        let reviewed = review(
            payeeID: "coffee", amountValue: #"{"num1":-1000,"num2":2000}"#, amountOperation: "isbetween"
        )
        var draft = ScheduleEditorDraft(review: reviewed, detail: detail(payeeID: "coffee"), currency: .usd)
        #expect(draft.amountWasUnsupported)
        #expect(try #require(draft.editFields(currency: .usd, locale: locale)).amount == .unchanged)

        draft.amountText = "10.00"
        draft.rangeEndText = "20.00"
        draft.amountWasChanged = true
        #expect(try #require(draft.editFields(currency: .usd, locale: locale)).amount
            == .set(.range(lower: -2_000, upper: -1_000)))
    }

    @Test func revertingEditedFieldsProducesNoCommandAndTrimsNameLikeStore() throws {
        let locale = Locale(identifier: "en_US")
        let reviewed = review(payeeID: "coffee")
        let detail = detail(payeeID: "coffee")
        var draft = ScheduleEditorDraft(review: reviewed, detail: detail, currency: .usd)

        draft.name = "Temporary name"
        draft.nameWasChanged = true
        draft.name = " Coffee "
        draft.amountText = "12.34"
        draft.amountInputWasEdited = true
        draft.amountWasChanged = true
        draft.amountText = "-45.00"
        draft.oneTimeDayID = "2026-10-01"
        draft.dateWasChanged = true
        draft.oneTimeDayID = "2026-09-28"

        let fields = try #require(draft.editFields(currency: .usd, locale: locale))
        #expect(fields.isEmpty)
        #expect(!draft.canSave(
            isCreate: false,
            capabilities: detail.capabilities,
            currency: .usd,
            locale: locale
        ))
    }

    @Test func monthlyDatePatternsRemainEditableAndUnchangedUntilUserChangesThem() throws {
        let recurrence = #"{"start":"2026-09-28","frequency":"monthly","interval":1,"patterns":[{"type":"MO","value":-1},{"type":"day","value":-1}]}"#
        let reviewed = review(payeeID: "coffee", dateValue: recurrence)
        let detail = detail(payeeID: "coffee")
        var draft = ScheduleEditorDraft(review: reviewed, detail: detail, currency: .usd)

        #expect(draft.patterns == [.weekday(.monday, ordinal: -1), .dayOfMonth(-1)])
        #expect(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US"))?.dateRule == .unchanged)

        draft.replacePattern(at: 0, with: .weekday(.friday, ordinal: 2))
        let fields = try #require(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US")))
        guard case .set(.some(.recurring(let edited, _))) = fields.dateRule else {
            Issue.record("An edited monthly pattern must produce the recurrence command")
            return
        }
        #expect(edited.patterns == [.weekday(.friday, ordinal: 2), .dayOfMonth(-1)])
    }

    @Test func yearlyRecurrencePatternsStayReadOnlyButMetadataRemainsEditable() throws {
        let recurrence = #"{"start":"2026-09-28","frequency":"yearly","interval":1,"patterns":[{"type":"MO","value":-1}]}"#
        let reviewed = review(payeeID: "coffee", dateValue: recurrence)
        let detail = detail(payeeID: "coffee")
        var draft = ScheduleEditorDraft(review: reviewed, detail: detail, currency: .usd)

        #expect(draft.hasUnsupportedDatePatterns)
        draft.dateWasChanged = true
        #expect(!draft.canSave(
            isCreate: false,
            capabilities: detail.capabilities,
            currency: .usd,
            locale: Locale(identifier: "en_US")
        ))

        draft.dateWasChanged = false
        draft.name = "Renamed"
        draft.nameWasChanged = true
        #expect(draft.canSave(
            isCreate: false,
            capabilities: detail.capabilities,
            currency: .usd,
            locale: Locale(identifier: "en_US")
        ))
        #expect(draft.editFields(currency: .usd, locale: Locale(identifier: "en_US"))?.dateRule == .unchanged)
    }

    @Test func privacyProjectionMasksEditorChoices() throws {
        let choices = ScheduleEditorChoices.project(
            TransactionEditorOptions(
                accounts: [ActualAccount(id: "checking", name: "Private Checking", offbudget: false, closed: false)],
                categories: [],
                categoryGroups: [],
                payees: [ActualPayee(id: "coffee", name: "Private Coffee", category: nil, transferAccount: nil)]
            ),
            privacyEnabled: true
        )
        #expect(!choices.accounts[0].title.contains("Private Checking"))
        #expect(!choices.payees[0].title.contains("Private Coffee"))
    }

    private func review(
        payeeID: String,
        dateValue: String = #""2026-09-28""#,
        amountValue: String = "-4500",
        amountOperation: String = "is"
    ) -> ScheduleMutationReview {
        ScheduleMutationReview(
            budgetID: "budget",
            scheduleID: "schedule",
            ruleID: "rule",
            schedule: ScheduleRowRevision(
                name: "Coffee",
                completed: false,
                postsTransaction: false,
                customUpcomingLength: nil,
                sortOrder: nil,
                tombstone: false,
                active: true
            ),
            rule: ScheduleRuleRevision(
                conditionsJSON: """
                [{"field":"account","op":"is","value":"checking","type":"id"},
                 {"field":"payee","op":"is","value":"\(payeeID)","type":"id"},
                  {"field":"amount","op":"\(amountOperation)","value":\(amountValue),"type":"number"},
                  {"field":"date","op":"is","value":\(dateValue),"type":"date"}]
                """,
                actionsJSON: #"[{"op":"link-schedule","value":"schedule"}]"#,
                stage: "pre",
                conditionsOperation: "and",
                tombstone: false
            ),
            nextDates: [ScheduleNextDateRevision(
                id: "next-date",
                localDate: "2026-09-28",
                localTimestamp: "1",
                baseDate: "2026-09-28",
                baseTimestamp: "1",
                tombstone: false
            )],
            account: ScheduleAccountRevision(
                id: "checking",
                name: "Checking",
                offBudget: false,
                isClosed: false,
                tombstone: false
            )
        )
    }

    private func detail(
        payeeID: String,
        capabilities: ScheduleMutationCapabilities = ScheduleMutationCapabilities(
            canRead: true,
            canEditMetadata: true,
            canEditAccount: true,
            canEditPayee: true,
            canEditAmount: true,
            canEditDate: true,
            canSkip: true,
            canComplete: true,
            canDelete: true,
            canPost: false
        )
    ) -> ScheduleDetail {
        ScheduleDetail(
            id: "schedule",
            ruleID: "rule",
            name: "Coffee",
            amount: .exact(-4_500),
            dateRule: .oneTime(dayID: "2026-09-28", operation: "is"),
            account: ScheduleAccountReference(id: "checking", name: "Checking", availability: .available),
            payee: SchedulePayeeReference(id: payeeID, name: "Coffee Shop", isMissing: false),
            effectiveNextDate: "2026-09-28",
            status: .upcoming,
            completed: false,
            postsTransaction: false,
            customUpcomingLength: nil,
            sortOrder: nil,
            rawConditionsJSON: nil,
            rawActionsJSON: nil,
            capabilities: capabilities,
            unsupportedReasons: [],
            occurrenceIdentity: ScheduleOccurrenceIdentity(
                scheduleID: "schedule",
                nextDateRowID: "next-date",
                effectiveNextDate: "2026-09-28",
                localNextDateTimestamp: "1",
                baseNextDateTimestamp: "1"
            )
        )
    }

    @Test func amountSignToggleFlipsBetweenSpendAndDeposit() {
        #expect(ScheduleEditorAmountSign.spend.toggled == .deposit)
        #expect(ScheduleEditorAmountSign.deposit.toggled == .spend)
    }
}
