import SwiftUI

struct ScheduleDetailView: View {
    let viewModel: SchedulesViewModel
    let scheduleID: String
    let onEdit: (String) -> Void
    let onAction: (ScheduleManagementAction, String) -> Void
    let onPost: ((String) -> Void)?

    init(
        scheduleID: String,
        viewModel: SchedulesViewModel,
        onEdit: @escaping (String) -> Void,
        onAction: @escaping (ScheduleManagementAction, String) -> Void,
        onPost: ((String) -> Void)? = nil
    ) {
        self.scheduleID = scheduleID
        self.viewModel = viewModel
        self.onEdit = onEdit
        self.onAction = onAction
        self.onPost = onPost
    }

    var body: some View {
        Group {
            if let presentation = viewModel.detailPresentation(id: scheduleID) {
                detailContent(presentation)
            } else {
                ContentUnavailableView(
                    "Schedule Unavailable",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("This schedule is no longer available in the current budget session.")
                )
            }
        }
        .background(ActualistTheme.background)
        .navigationTitle("Schedule Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let presentation = viewModel.detailPresentation(id: scheduleID),
               hasManagementActions(presentation.capabilities) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if presentation.capabilities.canEdit {
                            Button("Edit Schedule", systemImage: "pencil") { onEdit(scheduleID) }
                                .accessibilityIdentifier("schedule-edit")
                        }
                        if presentation.capabilities.canSkip {
                            Button("Skip Next Date", systemImage: "forward.end") {
                                onAction(.skip, scheduleID)
                            }
                            .accessibilityIdentifier("schedule-skip")
                        }
                        if presentation.capabilities.canComplete {
                            Button("Mark Completed", systemImage: "checkmark.circle") {
                                onAction(.complete, scheduleID)
                            }
                            .accessibilityIdentifier("schedule-complete")
                        }
                        if presentation.capabilities.canPost, let onPost {
                            Button("Review Post", systemImage: "arrow.up.circle") {
                                onPost(scheduleID)
                            }
                            .accessibilityIdentifier("schedule-post-review-open")
                        }
                        if presentation.capabilities.canDelete {
                            Button("Delete Schedule", systemImage: "trash", role: .destructive) {
                                onAction(.delete, scheduleID)
                            }
                            .accessibilityIdentifier("schedule-delete")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Manage Schedule")
                    .accessibilityIdentifier("schedule-manage")
                }
            }
        }
    }

    private func detailContent(_ presentation: ScheduleDetailPresentation) -> some View {
        ReviewSheetContent {
            VStack(spacing: 10) {
                ReviewSheetHeader(title: presentation.title)
                Text(presentation.amountText)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(presentation.statusTone.color)
                    .multilineTextAlignment(.center)
                Text(presentation.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(presentation.statusTone.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(presentation.statusTone.color.opacity(0.13), in: Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)

            Text("Schedule")
                .font(.headline.weight(.bold))
            VStack(spacing: 10) {
                ReviewSummaryRow(title: "Status", value: presentation.statusText,
                                 symbol: "clock", valueColor: presentation.statusTone.color)
                ReviewSummaryRow(title: "State", value: presentation.stateText, symbol: "checkmark.circle")
                ReviewSummaryRow(title: "Next date", value: presentation.dateText, symbol: "calendar")
                ReviewSummaryRow(title: "Repeats", value: presentation.recurrenceText, symbol: "repeat")
                if let weekendText = presentation.weekendText {
                    ReviewSummaryRow(title: "Weekend", value: weekendText, symbol: "sun.max")
                }
                if let endingText = presentation.endingText {
                    ReviewSummaryRow(title: "Ends", value: endingText, symbol: "flag")
                }
                ReviewSummaryRow(title: "Upcoming window", value: presentation.upcomingWindowText,
                                 symbol: "calendar.badge.clock")
            }
            .actualistReviewCard(padding: 12)

            Text("Transaction")
                .font(.headline.weight(.bold))
            VStack(spacing: 10) {
                ReviewSummaryRow(title: "Amount", value: presentation.amountText, symbol: "dollarsign.circle")
                ReviewSummaryRow(
                    title: "Account",
                    value: presentation.accountText,
                    symbol: accountSymbol(presentation.accountAvailability),
                    valueColor: accountTone(presentation.accountAvailability).color
                )
                .accessibilityIdentifier("schedule-detail-account")
                ReviewSummaryRow(
                    title: "Payee",
                    value: presentation.payeeText,
                    symbol: presentation.payeeIsMissing
                        ? "person.crop.circle.badge.exclamationmark"
                        : "person.crop.circle",
                    valueColor: presentation.payeeIsMissing ? ActualistTheme.warning : nil
                )
                .accessibilityIdentifier("schedule-detail-payee")
                ReviewSummaryRow(title: "Automatic posting", value: presentation.automaticPostingText,
                                 symbol: "bolt.circle")
                    .accessibilityIdentifier("schedule-detail-automatic-posting")
            }
            .actualistReviewCard(padding: 12)
            Text("Automatic posting is shown as stored in the budget. This read-only screen does not post transactions.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("Availability")
                .font(.headline.weight(.bold))
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    hasManagementActions(presentation.capabilities)
                        ? "Available in Actualist"
                        : "Read-only in Actualist",
                    systemImage: hasManagementActions(presentation.capabilities) ? "checkmark.circle" : "lock.fill"
                )
                    .foregroundStyle(ActualistTheme.secondaryText)

                ForEach(presentation.unsupportedMessages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ActualistTheme.warning)
                }
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard()
            Text(
                presentation.unsupportedMessages.isEmpty
                    ? "Viewing this schedule does not change it. Available management actions require a separate review."
                    : "The original schedule remains readable and unchanged. Unsupported options are not approximated or rewritten."
            )
            .font(.footnote)
            .foregroundStyle(ActualistTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("schedule-detail-content")
    }

    private func accountSymbol(_ availability: ScheduleReferenceAvailability) -> String {
        switch availability {
        case .available: "building.columns"
        case .closed: "archivebox"
        case .missing: "building.columns.fill"
        }
    }

    private func accountTone(
        _ availability: ScheduleReferenceAvailability
    ) -> SchedulePresentationTone {
        switch availability {
        case .available: .neutral
        case .closed: .warning
        case .missing: .danger
        }
    }

    private func hasManagementActions(_ capabilities: ScheduleMutationCapabilities) -> Bool {
        capabilities.canEdit || capabilities.canSkip || capabilities.canComplete
            || (capabilities.canPost && onPost != nil) || capabilities.canDelete
    }
}
