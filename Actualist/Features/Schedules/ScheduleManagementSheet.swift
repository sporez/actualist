import SwiftUI

struct ScheduleManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Bindable var coordinator: ScheduleManagementCoordinator
    let mutationRepository: any ScheduleMutationRepositoryProtocol
    let currency: BudgetCurrency

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.state {
                case .idle:
                    ContentUnavailableView("Schedule", systemImage: "calendar")
                case .loading(let title):
                    ProgressView(title).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .editing(let session):
                    ScheduleEditorView(
                        coordinator: coordinator,
                        session: session,
                        currency: currency,
                        locale: locale
                    )
                case .reviewingSave(let session):
                    saveReview(session)
                case .reviewingAction(let review):
                    actionReview(review)
                case .submitting(let title):
                    ProgressView(title).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .committed(let outcome):
                    committed(outcome)
                case .noChanges(let outcome):
                    committed(outcome)
                case .failed(let message):
                    failure(message)
                }
            }
            .background(ActualistTheme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { close() }
                        .labelStyle(.iconOnly)
                        .disabled(coordinator.isSubmitting)
                        .accessibilityIdentifier("schedule-management-close")
                }
            }
        }
        .frame(idealWidth: 580)
        .presentationDetents([.large])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationBackground(ActualistTheme.background)
        .interactiveDismissDisabled(coordinator.isSubmitting)
    }

    @ViewBuilder
    private func saveReview(_ session: ScheduleEditorSession) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(
                title: session.scheduleID == nil ? "Review Schedule" : "Review Changes",
                subtitle: "Check the schedule details before saving."
            )
            VStack(spacing: 10) {
                ForEach(Array(session.draft.reviewRows(
                    currency: currency,
                    locale: locale,
                    choices: session.choices,
                    privacyEnabled: session.isPrivacyModeEnabled,
                    scheduleID: session.scheduleID ?? "new"
                ).enumerated()), id: \.offset) { _, row in
                    ReviewSummaryRow(title: row.0, value: row.1, symbol: reviewSymbol(row.0))
                }
            }
            .actualistReviewCard(padding: 12)
            if let notice = session.notice { noticeCard(notice, warning: true) }
            if session.draft.postsTransaction {
                Text("Automatic posting happens only after a successful sync opportunity.")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("schedule-save-review")
        .reviewSheetBottomBar {
            Button {
                coordinator.backToEditor()
            } label: {
                Text("Back")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)
            .disabled(coordinator.isSubmitting)
            Button {
                coordinator.confirmSave(locale: locale, mutationRepository: mutationRepository)
            } label: {
                Text("Save Schedule")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .accessibilityIdentifier("schedule-save-confirm")
        }
    }

    @ViewBuilder
    private func actionReview(_ review: ScheduleActionReview) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(
                title: review.action.title,
                subtitle: review.isPrivacyModeEnabled ? "Schedule" : (review.detail.name ?? "Schedule")
            )
            VStack(spacing: 10) {
                ReviewSummaryRow(title: "Amount", value: SchedulePresentation.amountLabel(
                    review.detail.amount,
                    currency: review.currency,
                    privacyEnabled: review.isPrivacyModeEnabled,
                    seed: "schedule-\(review.detail.id)"
                ), symbol: "dollarsign.circle")
                ReviewSummaryRow(
                    title: "Account",
                    value: review.isPrivacyModeEnabled
                        ? "Selected account"
                        : (review.detail.account.name ?? "Unavailable account"),
                    symbol: "building.columns"
                )
                ReviewSummaryRow(title: "Next date", value: SchedulePresentation.dateLabel(review.detail.effectiveNextDate), symbol: "calendar")
            }
            .actualistReviewCard(padding: 12)
            Text(actionExplanation(review.action))
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("schedule-action-review")
        .reviewSheetBottomBar {
            Button(role: .cancel) {
                coordinator.cancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("schedule-action-cancel")
            Button(role: review.action == .delete ? .destructive : nil) {
                coordinator.confirmAction(mutationRepository: mutationRepository)
            } label: {
                Text(review.action.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(review.action == .delete ? ActualistTheme.danger : ActualistTheme.accent)
            .accessibilityIdentifier("schedule-action-confirm")
        }
    }

    private func committed(_ outcome: ScheduleMutationOutcome) -> some View {
        let isUnchanged = outcome.receipt.kind == .unchanged
        return ReviewSheetContent {
            ReviewSheetHeader(title: committedTitle(outcome))
            Label(
                isUnchanged
                    ? "No schedule changes were needed. Nothing was submitted."
                    : (outcome.refreshPending
                        ? "Your change was saved. The schedule list is still refreshing."
                        : committedMessage(outcome)),
                systemImage: isUnchanged
                    ? "minus.circle"
                    : (outcome.refreshPending ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
            )
            .foregroundStyle(isUnchanged ? ActualistTheme.secondaryText : (outcome.refreshPending ? ActualistTheme.warning : ActualistTheme.positive))
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard()
            Text(isUnchanged
                ? "You can close this review. No schedule update was sent."
                : "You can close this review. The saved change will not be submitted again.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .reviewSheetBottomBar {
            Button {
                closeCommitted()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
        }
    }

    private func failure(_ message: String) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Schedule Not Changed")
            noticeCard(message, warning: false)
            Text("No new save will be sent from this message. Review the schedule again before trying another change.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .reviewSheetBottomBar {
            Button {
                close()
            } label: {
                Text("Close")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
        }
    }

    private func noticeCard(_ message: String, warning: Bool) -> some View {
        Label(message, systemImage: warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(warning ? ActualistTheme.warning : ActualistTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard(padding: 12)
    }

    private func committedTitle(_ outcome: ScheduleMutationOutcome) -> String {
        switch outcome.receipt.kind {
        case .created: "Schedule Created"
        case .updated: "Schedule Updated"
        case .deleted: "Schedule Deleted"
        case .skipped: "Next Date Skipped"
        case .completed: "Schedule Completed"
        case .unchanged: "No Changes"
        }
    }

    private func committedMessage(_ outcome: ScheduleMutationOutcome) -> String {
        switch outcome.receipt.kind {
        case .created: "Your new schedule was saved to this budget."
        case .updated: "Your schedule changes were saved to this budget."
        case .deleted: "The schedule was removed from this budget. Past transactions were not changed."
        case .skipped: "The next scheduled date was skipped. No transaction was posted."
        case .completed: "The schedule was marked completed. No transaction was posted."
        case .unchanged: "No schedule changes were needed."
        }
    }

    private func reviewSymbol(_ title: String) -> String {
        switch title {
        case "Name": "textformat"
        case "Account": "building.columns"
        case "Payee": "person.crop.circle"
        case "Amount": "dollarsign.circle"
        case "Date": "calendar"
        default: "info.circle"
        }
    }

    private func actionExplanation(_ action: ScheduleManagementAction) -> String {
        switch action {
        case .delete: "This permanently removes the schedule from the budget. Past transactions are not changed."
        case .skip: "The next scheduled date will advance by one occurrence. No transaction will be posted."
        case .complete: "This one-time schedule will be marked completed. No transaction will be posted."
        }
    }

    private func close() {
        coordinator.cancel()
        dismiss()
    }

    private func closeCommitted() {
        coordinator.finishCommitted()
        dismiss()
    }
}

struct ScheduleEditorView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var coordinator: ScheduleManagementCoordinator
    let session: ScheduleEditorSession
    let currency: BudgetCurrency
    let locale: Locale

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(
                title: session.scheduleID == nil ? "New Schedule" : "Edit Schedule",
                subtitle: "Changes stay local and are queued for sync."
            )
            if let notice = session.notice { noticeCard(notice) }
            if session.isPrivacyModeEnabled {
                Label("Names and amounts use sample values while privacy mode is on.", systemImage: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.warning)
            }
            metadataSection
            transactionSection
            dateSection
            postingSection
            if !session.capabilities.canEdit && session.scheduleID != nil {
                noticeCard("This schedule definition cannot be safely edited in Actualist.")
            }
        }
        .accessibilityIdentifier("schedule-editor")
        .scrollDismissesKeyboard(.interactively)
        .reviewSheetBottomBar {
            Button(role: .cancel) {
                coordinator.cancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)
            Button {
                coordinator.reviewSave(locale: locale)
            } label: {
                Text("Review")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .disabled(coordinator.isSubmitting)
            .accessibilityIdentifier("schedule-save-review-button")
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Schedule", symbol: "calendar")
            TextField(session.isPrivacyModeEnabled ? "Schedule name (hidden)" : "Schedule name (optional)", text: Binding(
                get: {
                    guard let draft else { return "" }
                    return session.isPrivacyModeEnabled && !draft.nameWasChanged ? "" : draft.name
                },
                set: { coordinator.setName($0) }
            ))
            .textInputAutocapitalization(.words)
            .accessibilityIdentifier("schedule-editor-name")
            .reviewSheetFieldStyle()
            .disabled(session.scheduleID != nil && !session.capabilities.canEditMetadata)
            if session.scheduleID != nil && !session.capabilities.canEditMetadata {
                Text("Schedule name cannot be changed safely.").font(.footnote).foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .actualistReviewCard()
    }

    private var transactionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Transaction", symbol: "arrow.left.arrow.right")
            Picker("Account", selection: Binding(
                get: { draft?.accountID },
                set: { coordinator.setAccount($0) }
            )) {
                if let accountID = draft?.accountID,
                   !session.choices.accounts.contains(where: { $0.id == accountID }) {
                    Text("Current account (unavailable)").tag(Optional(accountID))
                }
                Text("Choose account").tag(String?.none)
                ForEach(session.choices.accounts) { account in
                    Text(account.title).tag(Optional(account.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(!isCreate && !session.capabilities.canEditAccount)
            .accessibilityIdentifier("schedule-editor-account")

            Picker("Payee", selection: Binding(
                get: { draft?.payeeID },
                set: { coordinator.setPayee($0) }
            )) {
                if let payeeID = draft?.payeeID,
                   !session.choices.payees.contains(where: { $0.id == payeeID }) {
                    Text("Current payee (unavailable)").tag(Optional(payeeID))
                }
                Text("No payee").tag(String?.none)
                ForEach(session.choices.payees) { payee in
                    Text(payee.title).tag(Optional(payee.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(!isCreate && !session.capabilities.canEditPayee)
            .accessibilityIdentifier("schedule-editor-payee")

            Picker("Amount type", selection: Binding(
                get: { draft?.amountMode ?? .exact },
                set: { coordinator.setAmountMode($0) }
            )) {
                ForEach(ScheduleEditorAmountMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .disabled(!isCreate && !session.capabilities.canEditAmount)
            let amountLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            amountLayout {
                TextField("Amount", text: Binding(
                    get: {
                        guard let draft else { return "" }
                        return session.isPrivacyModeEnabled && !draft.amountInputWasEdited ? "" : draft.amountText
                    },
                    set: { coordinator.setAmount($0) }
                ))
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("schedule-editor-amount")
                .reviewSheetFieldStyle()
                if draft?.amountMode == .range {
                    Text("to").foregroundStyle(ActualistTheme.secondaryText)
                    TextField("Amount", text: Binding(
                        get: {
                            guard let draft else { return "" }
                            return session.isPrivacyModeEnabled && !draft.rangeEndInputWasEdited ? "" : draft.rangeEndText
                        },
                        set: { coordinator.setRangeEnd($0) }
                    ))
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("schedule-editor-amount-upper")
                    .reviewSheetFieldStyle()
                }
            }
            .disabled(!isCreate && !session.capabilities.canEditAmount)
            Text("Amounts use the selected budget’s currency and precision.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .actualistReviewCard()
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Date", symbol: "calendar.badge.clock")
            Picker("Schedule type", selection: Binding(
                get: { draft?.dateMode ?? .oneTime },
                set: { coordinator.setDateMode($0) }
            )) {
                ForEach(ScheduleEditorDateMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .disabled(!isCreate && !session.canEditDate)

            Picker("Date match", selection: Binding(
                get: { draft?.operation ?? "is" },
                set: { coordinator.setOperation($0) }
            )) {
                Text("On date").tag("is")
                Text("About this date").tag("isapprox")
            }
            .pickerStyle(.menu)
            .disabled(!isCreate && !session.canEditDate)

            if draft?.dateMode == .oneTime {
                DatePicker("Date", selection: oneTimeDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("schedule-editor-one-time-date")
            } else {
                recurringControls
            }
            if session.scheduleID != nil && !session.canEditDate {
                Text(dateLimitationText)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .actualistReviewCard()
        .disabled(!isCreate && !session.canEditDate)
    }

    private var recurringControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Starts", selection: recurrenceStartDate, displayedComponents: .date)
                .datePickerStyle(.compact)
            let recurrenceLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            recurrenceLayout {
                Picker("Repeats", selection: Binding(
                    get: { draft?.frequency ?? .monthly },
                    set: { coordinator.setFrequency($0) }
                )) {
                    Text("Day").tag(ActualScheduleFrequency.daily)
                    Text("Week").tag(ActualScheduleFrequency.weekly)
                    Text("Month").tag(ActualScheduleFrequency.monthly)
                    Text("Year").tag(ActualScheduleFrequency.yearly)
                }
                .pickerStyle(.menu)
                TextField("Every", text: Binding(
                    get: { draft?.intervalText ?? "1" },
                    set: { coordinator.setInterval($0) }
                ))
                .keyboardType(.numberPad)
                .frame(width: 54)
                .accessibilityLabel("Repeat interval")
                .reviewSheetFieldStyle()
                Text("interval").foregroundStyle(ActualistTheme.secondaryText)
            }
            if draft?.frequency == .monthly { monthlyPatternControls }
            Toggle("Move weekend dates", isOn: Binding(
                get: { draft?.skipWeekend ?? false },
                set: { coordinator.setSkipWeekend($0) }
            ))
            .accessibilityIdentifier("schedule-editor-skip-weekend")
            if draft?.skipWeekend == true {
                Picker("Weekend adjustment", selection: Binding(
                    get: { draft?.weekendAdjustment ?? .after },
                    set: { coordinator.setWeekendAdjustment($0) }
                )) {
                    Text("Before weekend").tag(ActualScheduleWeekendAdjustment.before)
                    Text("After weekend").tag(ActualScheduleWeekendAdjustment.after)
                }
                .pickerStyle(.menu)
            }
            Picker("Ends", selection: endingMode) {
                ForEach(ScheduleEditorEndingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            if draft?.endingMode == .afterOccurrences {
                TextField("Number of occurrences", text: Binding(
                    get: { draft?.endingCountText ?? "12" },
                    set: { coordinator.setEndingCount($0) }
                ))
                .keyboardType(.numberPad)
                .reviewSheetFieldStyle()
            } else if draft?.endingMode == .onDate {
                DatePicker("End date", selection: endingDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
        }
        .disabled(!isCreate && !session.canEditDate)
    }

    private var monthlyPatternControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft?.patterns.isEmpty == true
                ? "By default, this repeats on the start date’s day of the month."
                : "Monthly date patterns")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array((draft?.patterns ?? []).enumerated()), id: \.offset) { index, pattern in
                monthlyPatternRow(pattern, at: index)
                    .padding(.vertical, 3)
            }
            Menu {
                Button("Day of month", systemImage: "calendar") {
                    coordinator.addMonthlyDayPattern()
                }
                Button("Nth weekday", systemImage: "calendar.badge.clock") {
                    coordinator.addMonthlyWeekdayPattern()
                }
            } label: {
                Label("Add date pattern", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("schedule-pattern-add")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func monthlyPatternRow(_ pattern: ActualSchedulePattern, at index: Int) -> some View {
        let patternLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
        patternLayout {
            switch pattern {
            case .dayOfMonth(let day):
                Picker("Day of month", selection: Binding(
                    get: { day },
                    set: { coordinator.replacePattern(at: index, with: .dayOfMonth($0)) }
                )) {
                    ForEach(Self.monthDays, id: \.self) { value in
                        Text(Self.dayOfMonthLabel(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("schedule-pattern-day-\(index)")
            case .weekday(let weekday, let ordinal):
                Picker("Weekday", selection: Binding(
                    get: { weekday },
                    set: { coordinator.replacePattern(at: index, with: .weekday($0, ordinal: ordinal)) }
                )) {
                    ForEach(Self.weekdays, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("schedule-pattern-weekday-\(index)")
                Picker("Occurrence", selection: Binding(
                    get: { ordinal },
                    set: { coordinator.replacePattern(at: index, with: .weekday(weekday, ordinal: $0)) }
                )) {
                    ForEach(Self.weekdayOrdinals, id: \.self) { value in
                        Text(Self.ordinalLabel(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("schedule-pattern-ordinal-\(index)")
            }
            Button(role: .destructive) {
                coordinator.removePattern(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove date pattern")
            .accessibilityIdentifier("schedule-pattern-remove-\(index)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var postingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Options", symbol: "slider.horizontal.3")
            Toggle("Automatically post after sync", isOn: Binding(
                get: { draft?.postsTransaction ?? false },
                set: { coordinator.setPostsTransaction($0) }
            ))
            .disabled(!isCreate && !session.capabilities.canEditMetadata)
            Picker("Upcoming window", selection: Binding(
                get: { draft?.upcomingLength ?? "__budget_default__" },
                set: { coordinator.setUpcomingLength($0 == "__budget_default__" ? nil : $0) }
            )) {
                Text("Budget default").tag("__budget_default__")
                Text("7 days").tag("7")
                Text("14 days").tag("14")
                Text("30 days").tag("30")
                Text("Current month").tag("currentMonth")
                Text("One month").tag("oneMonth")
            }
            .pickerStyle(.menu)
            .disabled(!isCreate && !session.capabilities.canEditMetadata)
        }
        .actualistReviewCard()
    }

    private var oneTimeDate: Binding<Date> {
        Binding(
            get: { ScheduleEditorDraft.date(from: draft?.oneTimeDayID ?? session.asOfDayID) },
            set: { coordinator.setDay($0, recurringStart: false) }
        )
    }

    private var recurrenceStartDate: Binding<Date> {
        Binding(
            get: { ScheduleEditorDraft.date(from: draft?.recurrenceStartDayID ?? session.asOfDayID) },
            set: { coordinator.setDay($0, recurringStart: true) }
        )
    }

    private var endingDate: Binding<Date> {
        Binding(
            get: { ScheduleEditorDraft.date(from: draft?.endingDayID ?? session.asOfDayID) },
            set: { coordinator.setEndingDay($0) }
        )
    }

    private var endingMode: Binding<ScheduleEditorEndingMode> {
        Binding(
            get: { draft?.endingMode ?? .never },
            set: { coordinator.setEndingMode($0) }
        )
    }

    private var draft: ScheduleEditorDraft? {
        switch coordinator.state {
        case .editing(let current), .reviewingSave(let current): current.draft
        default: nil
        }
    }

    private var isCreate: Bool { session.scheduleID == nil }

    private var dateLimitationText: String {
        if draft?.hasUnsupportedDatePatterns == true {
            return "This schedule has date patterns outside the approved recurrence editor. Its original date rule will remain unchanged."
        }
        return "The original date options are unsupported and will remain unchanged."
    }

    private static let weekdays: [ActualScheduleWeekday] = [
        .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday
    ]
    private static let weekdayOrdinals: [Int] = [1, 2, 3, 4, 5, -1, -2, -3, -4, -5]
    private static let monthDays: [Int] = Array(1...31) + Array((-31)...(-1))

    private static func dayOfMonthLabel(_ day: Int) -> String {
        if day == -1 { return "Last day of month" }
        if day < 0 { return "\(-day) days from month end" }
        return "Day \(day)"
    }

    private static func ordinalLabel(_ ordinal: Int) -> String {
        if ordinal == -1 { return "Last" }
        if ordinal < 0 { return "\(-ordinal) from last" }
        return switch ordinal {
        case 1: "First"
        case 2: "Second"
        case 3: "Third"
        case 4: "Fourth"
        default: "Fifth"
        }
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline.weight(.bold))
            .foregroundStyle(ActualistTheme.primaryText)
    }

    private func noticeCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(ActualistTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard(padding: 12)
    }
}

private extension ActualScheduleWeekday {
    var title: String {
        switch self {
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        case .sunday: "Sun"
        }
    }
}
