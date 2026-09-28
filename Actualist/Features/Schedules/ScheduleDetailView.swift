import SwiftUI

struct ScheduleDetailView: View {
    let viewModel: SchedulesViewModel
    let scheduleID: String

    init(scheduleID: String, viewModel: SchedulesViewModel) {
        self.scheduleID = scheduleID
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            if let presentation = viewModel.detailPresentation(id: scheduleID) {
                detailList(presentation)
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
    }

    private func detailList(_ presentation: ScheduleDetailPresentation) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Text(presentation.amountText)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(presentation.statusTone.color)
                    Text(presentation.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(presentation.statusTone.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Section("Schedule") {
                LabeledContent("Status", value: presentation.statusText)
                LabeledContent("State", value: presentation.stateText)
                LabeledContent("Next date", value: presentation.dateText)
                LabeledContent("Repeats", value: presentation.recurrenceText)
                if let weekendText = presentation.weekendText {
                    LabeledContent("Weekend", value: weekendText)
                }
                if let endingText = presentation.endingText {
                    LabeledContent("Ends", value: endingText)
                }
                LabeledContent("Upcoming window", value: presentation.upcomingWindowText)
            }

            Section {
                LabeledContent("Amount", value: presentation.amountText)
                referenceRow(
                    title: "Account",
                    value: presentation.accountText,
                    systemImage: accountSymbol(presentation.accountAvailability),
                    tone: accountTone(presentation.accountAvailability)
                )
                referenceRow(
                    title: "Payee",
                    value: presentation.payeeText,
                    systemImage: presentation.payeeIsMissing
                        ? "person.crop.circle.badge.exclamationmark"
                        : "person.crop.circle",
                    tone: presentation.payeeIsMissing ? .warning : .neutral
                )
                LabeledContent("Automatic posting", value: presentation.automaticPostingText)
            } header: {
                Text("Transaction")
            } footer: {
                Text("Automatic posting is shown as stored in the budget. This read-only screen does not post transactions.")
            }

            Section {
                Label("Read-only in Actualist", systemImage: "lock.fill")
                    .foregroundStyle(ActualistTheme.secondaryText)

                ForEach(presentation.unsupportedMessages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ActualistTheme.warning)
                }
            } header: {
                Text("Availability")
            } footer: {
                Text(
                    presentation.unsupportedMessages.isEmpty
                        ? "Viewing this schedule does not change it. Editing and management controls are not available on this screen."
                        : "The original schedule remains readable and unchanged. Unsupported options are not approximated or rewritten."
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
    }

    private func referenceRow(
        title: String,
        value: String,
        systemImage: String,
        tone: SchedulePresentationTone
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                Text(value)
            }
            .foregroundStyle(tone.color)
            .multilineTextAlignment(.trailing)
        }
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
}
