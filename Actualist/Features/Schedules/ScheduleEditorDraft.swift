import Foundation

enum ScheduleEditorAmountMode: String, CaseIterable, Identifiable, Sendable {
    case exact
    case approximate
    case range

    var id: String { rawValue }
    var title: String {
        switch self {
        case .exact: "Exact"
        case .approximate: "About"
        case .range: "Range"
        }
    }
}

/// The direction of a schedule amount. The field holds positive digits and the
/// draft applies this sign when it builds a command, so the decimal pad needs no
/// minus key.
enum ScheduleEditorAmountSign: String, CaseIterable, Identifiable, Sendable {
    case spend = "Spend"
    case deposit = "Deposit"

    var id: String { rawValue }

    fileprivate func apply(to magnitude: Int) -> Int {
        self == .spend ? -magnitude : magnitude
    }
}

enum ScheduleEditorDateMode: String, CaseIterable, Identifiable, Sendable {
    case oneTime
    case recurring

    var id: String { rawValue }
    var title: String { self == .oneTime ? "One time" : "Repeating" }
}

enum ScheduleEditorEndingMode: Int, CaseIterable, Identifiable, Sendable {
    case never
    case afterOccurrences
    case onDate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .afterOccurrences: "After occurrences"
        case .onDate: "On date"
        }
    }
}

struct ScheduleEditorAccountChoice: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct ScheduleEditorPayeeChoice: Identifiable, Hashable, Sendable {
    /// Canonical payee ID; Actual creates its self-mapping with this same ID.
    let id: String
    let title: String
    let isTransfer: Bool
}

struct ScheduleEditorChoices: Hashable, Sendable {
    let accounts: [ScheduleEditorAccountChoice]
    let payees: [ScheduleEditorPayeeChoice]

    var payeePickerItems: [PayeePickerItem] {
        payees.map { PayeePickerItem(id: $0.id, title: $0.title, isTransfer: $0.isTransfer) }
    }

    func payeeTitle(for payeeID: String?) -> String {
        guard let payeeID else { return "No payee" }
        return payees.first { $0.id == payeeID }?.title ?? "Current payee (unavailable)"
    }

    static func project(
        _ options: TransactionEditorOptions,
        privacyEnabled: Bool = false
    ) -> ScheduleEditorChoices {
        let accounts = options.accounts
            .filter { !$0.closed }
            .map { account in
                ScheduleEditorAccountChoice(
                    id: account.id,
                    title: privacyEnabled
                        ? PrivacyDisplay.name(for: .account, seed: "schedule-account-\(account.id)")
                        : account.name
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let payeeNames = TransactionEditorPayeeOptions(accounts: options.accounts, payees: options.payees)
        let payees = options.payees.compactMap { payee -> ScheduleEditorPayeeChoice? in
            guard let id = payee.id, !id.isEmpty else { return nil }
            let rawTitle = payeeNames.displayName(for: payee).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = privacyEnabled
                ? PrivacyDisplay.name(for: .payee, seed: "schedule-payee-\(id)")
                : rawTitle
            guard !title.isEmpty else { return nil }
            return ScheduleEditorPayeeChoice(id: id, title: title, isTransfer: payee.transferAccount != nil)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return ScheduleEditorChoices(accounts: accounts, payees: payees)
    }
}

private struct ScheduleEditorOriginalValues: Hashable, Sendable {
    let name: String?
    let accountID: String?
    let payeeID: String?
    let amount: ScheduleAmountDraft?
    let dateRule: ScheduleDateRule
    let postsTransaction: Bool
    let upcomingLength: String?
}

struct ScheduleEditorDraft: Hashable, Sendable {
    private var originalValues: ScheduleEditorOriginalValues? = nil
    var name: String
    var accountID: String?
    var payeeID: String?
    var payeeWasChanged = false
    var amountWasUnsupported = false
    var dateRuleWasUnsupported = false
    var amountMode: ScheduleEditorAmountMode = .exact
    /// New schedules default to Spend; an existing schedule shows its stored sign.
    var amountSign: ScheduleEditorAmountSign = .spend
    var amountText = ""
    var rangeEndText = ""
    var dateMode: ScheduleEditorDateMode = .oneTime
    var oneTimeDayID: String
    var recurrenceStartDayID: String
    var operation = "is"
    var frequency: ActualScheduleFrequency = .monthly
    var intervalText = "1"
    var patterns: [ActualSchedulePattern] = []
    var skipWeekend = false
    var weekendAdjustment: ActualScheduleWeekendAdjustment = .after
    /// The single source of ending state. The count and day below are only the
    /// inputs of their own mode and are reset whenever the mode is left.
    private(set) var endingMode: ScheduleEditorEndingMode = .never
    var endingCountText = Self.defaultEndingCountText
    var endingDayID: String
    var postsTransaction = false
    var upcomingLength: String?

    var accountWasChanged = false
    var amountWasChanged = false
    var amountInputWasEdited = false
    var rangeEndInputWasEdited = false
    var dateWasChanged = false
    var nameWasChanged = false
    var postingWasChanged = false
    var upcomingWasChanged = false

    init(todayDayID: String) {
        name = ""
        accountID = nil
        payeeID = nil
        oneTimeDayID = todayDayID
        recurrenceStartDayID = todayDayID
        endingDayID = todayDayID
    }

    init(
        review: ScheduleMutationReview,
        detail: ScheduleDetail,
        currency: BudgetCurrency
    ) {
        let projection = ScheduleRuleProjection.read(
            scheduleID: review.scheduleID,
            conditionsJSON: review.rule.conditionsJSON,
            actionsJSON: review.rule.actionsJSON
        )
        name = review.schedule.name ?? ""
        accountID = projection.accountID
        // This is display-only. An untouched legacy alias remains `.unchanged`.
        payeeID = detail.payee.id
        switch projection.amount {
        case .exact(let value):
            amountMode = .exact
            amountSign = value < 0 ? .spend : .deposit
            amountText = Self.preciseEditableAmountText(abs(value), currency: currency)
        case .approximate(let value):
            amountMode = .approximate
            amountSign = value < 0 ? .spend : .deposit
            amountText = Self.preciseEditableAmountText(abs(value), currency: currency)
        case .range(let lower, let upper, _):
            amountMode = .range
            if upper <= 0 && lower < 0 {
                amountSign = .spend
                amountText = Self.preciseEditableAmountText(-upper, currency: currency)
                rangeEndText = Self.preciseEditableAmountText(-lower, currency: currency)
            } else if lower >= 0 {
                amountSign = .deposit
                amountText = Self.preciseEditableAmountText(lower, currency: currency)
                rangeEndText = Self.preciseEditableAmountText(upper, currency: currency)
            } else {
                // A range that crosses zero has no single Spend or Deposit sign.
                // It stays unchanged until the user enters a new amount.
                amountWasUnsupported = true
            }
        case .unavailable:
            amountWasUnsupported = true
            amountText = ""
        }
        postsTransaction = review.schedule.postsTransaction
        upcomingLength = review.schedule.customUpcomingLength
        switch projection.dateRule {
        case .oneTime(let dayID, let operation):
            dateMode = .oneTime
            oneTimeDayID = dayID
            recurrenceStartDayID = dayID
            self.operation = operation
            endingDayID = dayID
        case .recurring(let recurrence, let operation):
            dateMode = .recurring
            oneTimeDayID = recurrence.startDayID
            recurrenceStartDayID = recurrence.startDayID
            self.operation = operation
            frequency = recurrence.frequencyValue
            intervalText = String(recurrence.interval)
            patterns = recurrence.patterns
            if frequency != .monthly && !patterns.isEmpty {
                // The admitted recurrence contract only gives pattern semantics
                // to monthly schedules; daily/weekly/yearly calculators ignore them.
                dateRuleWasUnsupported = true
            }
            skipWeekend = recurrence.skipWeekend
            weekendAdjustment = recurrence.weekendAdjustment
            switch recurrence.ending {
            case .never:
                endingDayID = recurrence.startDayID
            case .afterOccurrences(let count):
                endingMode = .afterOccurrences
                endingCountText = String(count)
                endingDayID = recurrence.startDayID
            case .onDate(let dayID):
                endingMode = .onDate
                endingDayID = dayID
            }
        case .unavailable:
            dateRuleWasUnsupported = true
            dateMode = .oneTime
            oneTimeDayID = detail.effectiveNextDate ?? ""
            recurrenceStartDayID = oneTimeDayID
            endingDayID = oneTimeDayID
        }
        originalValues = ScheduleEditorOriginalValues(
            name: Self.normalizedName(review.schedule.name),
            accountID: projection.accountID,
            payeeID: detail.payee.id,
            amount: Self.amountDraft(projection.amount),
            dateRule: projection.dateRule,
            postsTransaction: review.schedule.postsTransaction,
            upcomingLength: review.schedule.customUpcomingLength
        )
    }

    func amountDraft(currency: BudgetCurrency, locale: Locale) -> ScheduleAmountDraft? {
        guard let typed = Self.minorUnits(amountText, currency: currency, locale: locale) else { return nil }
        let first = abs(typed)
        switch amountMode {
        case .exact: return .exact(amountSign.apply(to: first))
        case .approximate: return .approximate(amountSign.apply(to: first))
        case .range:
            guard let typedEnd = Self.minorUnits(rangeEndText, currency: currency, locale: locale),
                  first <= abs(typedEnd) else {
                return nil
            }
            let second = abs(typedEnd)
            // Spend flips the order so the stored lower bound stays the smaller number.
            return amountSign == .spend
                ? .range(lower: -second, upper: -first)
                : .range(lower: first, upper: second)
        }
    }

    func dateRule() -> ScheduleDateRule? {
        let operation = operation == "isapprox" ? "isapprox" : "is"
        switch dateMode {
        case .oneTime:
            guard ActualScheduleRecurrence.date(from: oneTimeDayID) != nil else { return nil }
            return .oneTime(dayID: oneTimeDayID, operation: operation)
        case .recurring:
            guard let interval = Int(intervalText), interval > 0,
                  let ending = resolvedEnding(),
                  let recurrence = try? ActualScheduleRecurrence(
                    startDayID: recurrenceStartDayID,
                    frequency: frequency,
                    interval: interval,
                    patterns: patterns,
                    skipWeekend: skipWeekend,
                    weekendAdjustment: weekendAdjustment,
                    ending: ending
                  ) else { return nil }
            return .recurring(recurrence, operation: operation)
        }
    }

    static let defaultEndingCountText = "12"
    static let endingCountValidationMessage = "Enter a number of occurrences greater than zero."

    /// Nil when the selected ending's input is invalid (a non-positive or
    /// non-numeric count).
    func resolvedEnding() -> ActualScheduleEnding? {
        switch endingMode {
        case .never: return .never
        case .afterOccurrences:
            guard let count = Int(endingCountText.trimmingCharacters(in: .whitespaces)), count > 0 else {
                return nil
            }
            return .afterOccurrences(count)
        case .onDate: return .onDate(endingDayID)
        }
    }

    var hasInvalidEndingCount: Bool {
        dateMode == .recurring && endingMode == .afterOccurrences && resolvedEnding() == nil
    }

    /// Leaving a mode discards its input so a later return starts from the
    /// defaults instead of resurrecting a stale count or date.
    mutating func selectEndingMode(_ mode: ScheduleEditorEndingMode) {
        guard mode != endingMode else { return }
        endingCountText = Self.defaultEndingCountText
        endingDayID = recurrenceStartDayID
        endingMode = mode
        dateWasChanged = true
    }

    var hasUnsupportedDatePatterns: Bool {
        dateRuleWasUnsupported || (dateMode == .recurring && frequency != .monthly && !patterns.isEmpty)
    }

    mutating func addMonthlyDayPattern() {
        guard let date = ActualScheduleRecurrence.date(from: recurrenceStartDayID) else { return }
        let day = Calendar.actualScheduleGregorian.component(.day, from: date)
        patterns.append(.dayOfMonth(day))
        markPatternsChanged()
    }

    mutating func addMonthlyWeekdayPattern() {
        let calendar = Calendar.actualScheduleGregorian
        guard let date = ActualScheduleRecurrence.date(from: recurrenceStartDayID) else { return }
        let weekday = calendar.component(.weekday, from: date)
        let dayOfMonth = calendar.component(.day, from: date)
        let weekdays: [ActualScheduleWeekday] = [
            .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday
        ]
        guard let selectedDay = weekdays.first(where: { $0.calendarWeekday == weekday }) else { return }
        let ordinal = calendar.date(byAdding: .day, value: 7, to: date).map {
            calendar.component(.month, from: $0) == calendar.component(.month, from: date)
        } == true ? (dayOfMonth + 6) / 7 : -1
        patterns.append(.weekday(selectedDay, ordinal: ordinal))
        markPatternsChanged()
    }

    mutating func replacePattern(at index: Int, with pattern: ActualSchedulePattern) {
        guard patterns.indices.contains(index) else { return }
        patterns[index] = pattern
        markPatternsChanged()
    }

    mutating func removePattern(at index: Int) {
        guard patterns.indices.contains(index) else { return }
        patterns.remove(at: index)
        markPatternsChanged()
    }

    private mutating func markPatternsChanged() {
        dateWasChanged = true
    }

    func createDefinition(currency: BudgetCurrency, locale: Locale) -> ScheduleDefinitionDraft? {
        guard let accountID, !accountID.isEmpty,
              let amount = amountDraft(currency: currency, locale: locale),
              let dateRule = dateRule() else { return nil }
        return ScheduleDefinitionDraft(
            accountID: accountID,
            payeeMappingID: payeeID,
            amount: amount,
            dateRule: dateRule
        )
    }

    func editFields(
        currency: BudgetCurrency,
        locale: Locale
    ) -> ScheduleEditFields? {
        var fields = ScheduleEditFields()
        if nameWasChanged && (originalValues == nil || Self.normalizedName(name) != originalValues?.name) {
            fields.name = .set(name)
        }
        if accountWasChanged && (originalValues == nil || accountID != originalValues?.accountID) {
            fields.accountID = .set(accountID)
        }
        if payeeWasChanged && (originalValues == nil || payeeID != originalValues?.payeeID) {
            fields.payeeMappingID = .set(payeeID)
        }
        if amountWasChanged {
            guard let amount = amountDraft(currency: currency, locale: locale) else { return nil }
            if amount != originalValues?.amount || originalValues == nil {
                fields.amount = .set(amount)
            }
        }
        if dateWasChanged {
            guard let dateRule = dateRule() else { return nil }
            if dateRule != originalValues?.dateRule || originalValues == nil {
                fields.dateRule = .set(dateRule)
            }
        }
        if postingWasChanged
            && (originalValues == nil || postsTransaction != originalValues?.postsTransaction) {
            fields.postsTransaction = postsTransaction
        }
        if upcomingWasChanged
            && (originalValues == nil || upcomingLength != originalValues?.upcomingLength) {
            fields.customUpcomingLength = .set(upcomingLength)
        }
        return fields
    }

    func canSave(
        isCreate: Bool,
        capabilities: ScheduleMutationCapabilities,
        currency: BudgetCurrency,
        locale: Locale
    ) -> Bool {
        if isCreate { return createDefinition(currency: currency, locale: locale) != nil }
        guard let fields = editFields(currency: currency, locale: locale), !fields.isEmpty else { return false }
        if fields.accountID != .unchanged && !capabilities.canEditAccount { return false }
        if fields.accountID != .unchanged && accountID == nil { return false }
        if fields.payeeMappingID != .unchanged && !capabilities.canEditPayee { return false }
        if fields.amount != .unchanged && !capabilities.canEditAmount { return false }
        if fields.dateRule != .unchanged && !capabilities.canEditDate { return false }
        if fields.dateRule != .unchanged && hasUnsupportedDatePatterns { return false }
        if (fields.name != .unchanged || fields.postsTransaction != nil
            || fields.customUpcomingLength != .unchanged) && !capabilities.canEditMetadata {
            return false
        }
        return true
    }

    func validationMessage(
        isCreate: Bool,
        capabilities: ScheduleMutationCapabilities,
        currency: BudgetCurrency,
        locale: Locale
    ) -> String {
        if isCreate {
            guard accountID != nil else { return "Choose an open account." }
            guard amountDraft(currency: currency, locale: locale) != nil else {
                return amountMode == .range ? "Enter a valid amount range." : "Enter a valid amount."
            }
            if hasInvalidEndingCount { return Self.endingCountValidationMessage }
            guard dateRule() != nil else { return "Choose a valid schedule date and recurrence." }
            return "Check the schedule details and try again."
        }
        guard let fields = editFields(currency: currency, locale: locale) else {
            if amountWasChanged { return amountMode == .range ? "Enter a valid amount range." : "Enter a valid amount." }
            if dateWasChanged {
                return hasInvalidEndingCount
                    ? Self.endingCountValidationMessage
                    : "Choose a valid schedule date and recurrence."
            }
            return "Make a supported change before saving."
        }
        if fields.accountID != .unchanged && !capabilities.canEditAccount { return "The account option cannot be changed safely." }
        if fields.payeeMappingID != .unchanged && !capabilities.canEditPayee { return "The payee option cannot be changed safely." }
        if fields.amount != .unchanged && !capabilities.canEditAmount { return "The amount option cannot be changed safely." }
        if fields.dateRule != .unchanged && !capabilities.canEditDate { return "The date option cannot be changed safely." }
        if fields.dateRule != .unchanged && hasUnsupportedDatePatterns {
            return "This recurrence pattern is outside the approved editor and must remain unchanged."
        }
        if (fields.name != .unchanged || fields.postsTransaction != nil
            || fields.customUpcomingLength != .unchanged) && !capabilities.canEditMetadata {
            return "Schedule details cannot be changed safely."
        }
        return "Make a supported change before saving."
    }

    static func dayID(from date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func date(from dayID: String, timeZone: TimeZone = .autoupdatingCurrent) -> Date {
        let parts = dayID.split(separator: "-").compactMap { Int(String($0)) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else {
            return Date()
        }
        return date
    }

    private static func minorUnits(_ text: String, currency: BudgetCurrency, locale: Locale) -> Int? {
        guard let amount = try? BudgetMoneyInputFormat(currency: currency, locale: locale).parse(text) else {
            return nil
        }
        return currency.minorUnits(fromDisplay: amount)
    }

    private static func normalizedName(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func amountDraft(_ amount: ScheduleAmount) -> ScheduleAmountDraft? {
        switch amount {
        case .exact(let value): .exact(value)
        case .approximate(let value): .approximate(value)
        case .range(let lower, let upper, _): .range(lower: lower, upper: upper)
        case .unavailable: nil
        }
    }

    private static func preciseEditableAmountText(_ value: Int, currency: BudgetCurrency) -> String {
        // Display preferences such as hide-fraction must not alter an editable value.
        var editingCurrency = currency
        editingCurrency.hideFraction = false
        return editingCurrency.editableAmountText(fromMinorUnits: value)
    }
}
