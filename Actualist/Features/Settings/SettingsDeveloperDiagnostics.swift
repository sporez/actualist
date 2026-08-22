import SwiftUI

struct SettingsDeveloperDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var randomizedDisplayValuesSelection: Bool
    let hideDeveloperMode: () -> Void
    let debug: BackgroundRefreshDebugInfo
    let syncStatus: LocalFirstSyncStatus?
    let syncDebug: LocalFirstSyncDebugInfo
    let endpointHealth: ServerEndpointHealthDisplay
    let retryPendingSync: () async -> Void
    @State private var isRetryingSync = false
    #if DEBUG
    @Binding var isPostingDebugNotification: Bool
    @Binding var debugNotificationMessage: String?
    let postDebugNotification: () async -> Void
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy") {
                    Toggle("Generic Screenshot Data", isOn: $randomizedDisplayValuesSelection)
                }
                .settingsSectionChrome()

                Section("Local-First Sync") {
                    LocalFirstSyncDiagnosticRows(
                        status: syncStatus,
                        debug: syncDebug,
                        endpointHealth: endpointHealth
                    )

                    Button {
                        Task { await retrySync() }
                    } label: {
                        SettingsActionLabel(
                            title: isRetryingSync ? "Retrying Sync" : "Retry Pending Sync",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(isRetryingSync || syncStatus?.pendingLocalMessageCount == 0)
                }
                .settingsSectionChrome()

                #if DEBUG
                Section("Notifications") {
                    Button {
                        Task { await postDebugNotification() }
                    } label: {
                        SettingsActionLabel(
                            title: isPostingDebugNotification ? "Posting Test Alert" : "Post Test Transaction Alert",
                            systemImage: "bell.badge"
                        )
                    }
                    .disabled(isPostingDebugNotification)

                    if let debugNotificationMessage {
                        Text(debugNotificationMessage)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                }
                .settingsSectionChrome()
                #endif

                Section("Background Refresh Logs") {
                    BackgroundRefreshDebugRows(debug: debug)
                }
                .settingsSectionChrome()

                Section("Developer Mode") {
                    Button(role: .destructive) {
                        hideDeveloperMode()
                    } label: {
                        SettingsActionLabel(title: "Hide Developer Mode", systemImage: "eye.slash")
                    }
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .appSwitcherPrivacyProtected()
    }

    private func retrySync() async {
        guard !isRetryingSync else {
            return
        }
        isRetryingSync = true
        await retryPendingSync()
        isRetryingSync = false
    }
}

private struct LocalFirstSyncDiagnosticRows: View {
    let status: LocalFirstSyncStatus?
    let debug: LocalFirstSyncDebugInfo
    let endpointHealth: ServerEndpointHealthDisplay

    var body: some View {
        LabeledContent("Endpoint cache") {
            Text(endpointHealth.summaryText)
                .foregroundStyle(
                    endpointHealth.willSkipPrimary
                        ? ActualistTheme.warning
                        : ActualistTheme.secondaryText
                )
        }

        ForEach(endpointHealth.pairs) { pair in
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(pair.isCurrentPair ? "Primary" : "Cached primary") {
                    Text(pair.statusText)
                        .foregroundStyle(
                            pair.isDown ? ActualistTheme.warning : ActualistTheme.secondaryText
                        )
                }
                Text(pair.primaryHost)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.primaryText)
                if !pair.fallbackHost.isEmpty {
                    Text(pair.fallbackHost)
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }

        LabeledContent("Pending Changes") {
            Text((status?.pendingLocalMessageCount ?? 0).formatted())
                .foregroundStyle(pendingColor)
        }

        LabeledContent("Last Attempt") {
            Text(formattedDate(status?.lastSyncAttemptAt))
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        LabeledContent("Last Success") {
            Text(formattedDate(status?.lastSyncedAt))
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if let status {
            LabeledContent("Last Upload") {
                Text(status.lastUploadedMessageCount.formatted())
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            LabeledContent("Last Download") {
                Text(status.lastAppliedMessageCount.formatted())
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            if let error = status.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
            }
        }

        LabeledContent("Recorded Events") {
            Text(debug.totalEventCount.formatted())
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if debug.recentEvents.isEmpty {
            Text("No local-first sync events recorded yet")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            ForEach(debug.recentEvents.prefix(20)) { event in
                LocalFirstSyncDebugEventRow(event: event)
            }
        }
    }

    private var pendingColor: Color {
        (status?.pendingLocalMessageCount ?? 0) == 0
            ? ActualistTheme.secondaryText
            : ActualistTheme.warning
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "Never"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}

private struct LocalFirstSyncDebugEventRow: View {
    let event: LocalFirstSyncDebugEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 8)

                Text(outcomeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(outcomeColor)
            }

            Text(event.message)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)

            HStack(spacing: 6) {
                if let endpoint = event.endpoint {
                    Text(endpoint == .fallback ? "Fallback" : "Primary")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(endpointColor(endpoint))
                }
                Text("Pending \(event.pendingBefore) → \(event.pendingAfter) · Uploaded \(event.uploadedCount) · Downloaded \(event.downloadedCount)")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    private var outcomeTitle: String {
        switch event.outcome {
        case .queued: "Queued"
        case .succeeded: "Confirmed"
        case .failed: "Failed"
        }
    }

    private var outcomeColor: Color {
        switch event.outcome {
        case .queued: ActualistTheme.warning
        case .succeeded: ActualistTheme.positive
        case .failed: ActualistTheme.danger
        }
    }

    private func endpointColor(_ endpoint: LocalFirstSyncDebugEvent.Endpoint) -> Color {
        endpoint == .fallback ? ActualistTheme.accent : ActualistTheme.secondaryText
    }
}

struct SettingsActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(ActualistTheme.primaryText)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(ActualistTheme.accent)
        }
    }
}

struct SettingsStatusRow: View {
    let status: ServerConnectionStatus
    var usedFallback: Bool = false

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.45), radius: 4)

                Text(title)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
    }

    private var title: String {
        switch status {
        case .online:
            usedFallback ? "Connected (via fallback)" : "Connected"
        case .connecting:
            "Checking"
        case .offline:
            "Offline"
        }
    }

    private var color: Color {
        switch status {
        case .online:
            ActualistTheme.positive
        case .connecting:
            ActualistTheme.warning
        case .offline:
            ActualistTheme.danger
        }
    }
}

private struct BackgroundRefreshDebugRows: View {
    let debug: BackgroundRefreshDebugInfo

    var body: some View {
        LabeledContent("Schedule Count") {
            Text(debug.scheduleAttemptCount.formatted())
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if debug.recentScheduleAttempts.isEmpty {
            Text("No schedule attempts yet")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            ForEach(debug.recentScheduleAttempts.prefix(5)) { attempt in
                BackgroundRefreshScheduleAttemptRow(attempt: attempt)
            }
        }

        LabeledContent("Wake Count") {
            Text(debug.wakeCount.formatted())
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if debug.recentRuns.isEmpty {
            Text("No background wakes yet")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            ForEach(debug.recentRuns.prefix(20)) { run in
                BackgroundRefreshDebugRunRow(run: run)
            }
        }
    }
}

private struct BackgroundRefreshScheduleAttemptRow: View {
    let attempt: BackgroundRefreshScheduleAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formattedDate(attempt.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 8)

                Text(attempt.succeeded ? "Accepted" : "Rejected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(attempt.succeeded ? ActualistTheme.positive : ActualistTheme.danger)
            }

            if let earliestBeginDate = attempt.earliestBeginDate {
                Text("Earliest \(formattedDate(earliestBeginDate))")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            Text(attempt.message)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "Not yet"
        }

        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}

private struct BackgroundRefreshDebugRunRow: View {
    let run: BackgroundRefreshDebugRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formattedDate(run.wakeDate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 8)

                Text(resultText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resultColor)
            }

            if let completionDate = run.completionDate {
                Text("Finished \(formattedDate(completionDate))")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            Text(run.message)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .lineLimit(4)
        }
        .padding(.vertical, 2)
    }

    private var resultText: String {
        guard let succeeded = run.succeeded else {
            return "Started"
        }

        return succeeded ? "Succeeded" : "Failed"
    }

    private var resultColor: Color {
        switch run.succeeded {
        case true:
            ActualistTheme.positive
        case false:
            ActualistTheme.danger
        case nil:
            ActualistTheme.secondaryText
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "Not yet"
        }

        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}
