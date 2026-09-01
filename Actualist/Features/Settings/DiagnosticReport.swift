import CoreTransferable
import Darwin
import Foundation
import UIKit
import UniformTypeIdentifiers

struct ActualistDiagnosticReport: Equatable, Sendable, Transferable {
    let text: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { report in
            Data(report.text.utf8)
        }
        .suggestedFileName { report in
            report.filename
        }
    }
}

@MainActor
enum ActualistDiagnosticReportBuilder {
    static func make(
        appState: AppState,
        generatedAt: Date = Date(),
        reportID: UUID = UUID()
    ) -> ActualistDiagnosticReport {
        let settings = appState.settings
        let store = appState.localFirstStore
        let syncStatus = appState.localFirstSyncStatus
        let redactor = DiagnosticReportRedactor(sensitiveValues: sensitiveValues(appState: appState))
        let processInfo = ProcessInfo.processInfo
        let application = UIApplication.shared
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let pendingNotificationCounts = settings.pendingNewTransactionIDsByAccount.values.map(\.count)
        let selectedDatabaseURL = settings.selectedLocalFirstFileID.flatMap {
            try? store.fileManager.databaseURL(fileID: $0)
        }
        let importedBudgetCount = (try? store.fileManager.importedBudgetFileIDs().count) ?? 0
        let availableStorageBytes = availableStorageBytes()

        var lines: [String] = [
            "Actualist Diagnostic Report",
            "Report ID: \(reportID.uuidString)",
            "Generated: \(timestamp(generatedAt))",
            "Privacy: This report intentionally excludes credentials, server addresses, identifiers, names, budget contents, transaction details, and financial amounts.",
            "",
            "[Application]",
            "Version: \(version) (\(build))",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "Unknown")",
            "Build configuration: \(buildConfiguration)",
            "Process uptime seconds: \(Int(processInfo.systemUptime))",
            "",
            "[Device]",
            "Hardware model: \(hardwareModel)",
            "Operating system: \(processInfo.operatingSystemVersionString)",
            "Processor count: \(processInfo.processorCount)",
            "Active processor count: \(processInfo.activeProcessorCount)",
            "Physical memory bytes: \(processInfo.physicalMemory)",
            "Low Power Mode: \(yesNo(processInfo.isLowPowerModeEnabled))",
            "Thermal state: \(thermalState(processInfo.thermalState))",
            "Application state: \(applicationState(application.applicationState))",
            "Protected data available: \(yesNo(application.isProtectedDataAvailable))",
            "System background refresh: \(backgroundRefreshStatus(application.backgroundRefreshStatus))",
            "Available storage bytes: \(availableStorageBytes.map(String.init) ?? "Unknown")",
            "Locale: \(Locale.current.identifier)",
            "Preferred language: \(Locale.preferredLanguages.first ?? "Unknown")",
            "Time zone offset seconds: \(TimeZone.current.secondsFromGMT(for: generatedAt))",
            "",
            "[Session]",
            "Setup phase: \(setupPhase(appState.setupPhase))",
            "Connection status: \(connectionStatusLine(appState))",
            "Selected tab: \(appState.selectedTab.rawValue)",
            "Server configured: \(yesNo(!settings.localFirstServerURLString.isEmpty))",
            "Server transport: \(serverTransport(settings.localFirstServerURLString))",
            "Credentials available: \(yesNo(appState.hasSyncCredentials))",
            "Discovered budget count: \(appState.budgets.count)",
            "Budget selected: \(yesNo(settings.selectedBudgetID != nil))",
            "Local data revision: \(appState.localDataRevision)",
            "Last app error: \(redactor.redact(appState.lastErrorMessage))",
            "",
            "[Preferences]",
            "Theme: \(settings.theme.rawValue)",
            "Display density: \(settings.displayDensity.rawValue)",
            "Green income amounts: \(yesNo(settings.greenIncomeTransactionAmountsEnabled))",
            "Rollover overspent alerts: \(yesNo(settings.includeCarryoverCategoriesInOverspentAlerts))",
            "Show total assigned: \(yesNo(settings.showTotalAssigned))",
            "Hide carryover arrows: \(yesNo(settings.hideCarryoverArrows))",
            "Show hidden categories: \(yesNo(settings.showHiddenCategories))",
            "Sample display values: \(yesNo(settings.randomizedDisplayValuesEnabled))",
            "Background transaction alerts: \(yesNo(settings.backgroundTransactionRefreshEnabled))",
            "Background bank sync: \(yesNo(settings.simplefinBackgroundSyncEnabled))",
            "Developer mode unlocked: \(yesNo(settings.developerModeUnlocked))",
            "Experimental features enabled: \(list(settings.enabledExperimentalFeatures.map(\.rawValue).sorted()))",
            "Report card order: \(settings.reportCardOrder.map(\.rawValue).joined(separator: ", "))",
            "",
            "[Selected Budget Metadata]",
            "Budget ID present: \(yesNo(settings.selectedBudgetID != nil))",
            "Budget name present: \(yesNo(settings.selectedBudgetName != nil))",
            "Local file ID present: \(yesNo(settings.selectedLocalFirstFileID != nil))",
            "Sync group ID present: \(yesNo(settings.selectedLocalFirstGroupID != nil))",
            "Encryption enabled: \(yesNo(syncStatus?.encryptionKeyID != nil || store.openedEncryptionContext != nil))",
            "",
            "[Local Store]",
            "Budget open: \(yesNo(store.hasOpenBudget))",
            "Open budget matches selection: \(yesNo(store.openedBudgetID != nil && store.openedBudgetID == settings.selectedBudgetID))",
            "Database open: \(yesNo(store.database != nil))",
            "Node ID present: \(yesNo(store.openedNodeID != nil))",
            "Open group ID present: \(yesNo(store.openedGroupID != nil))",
            "Open server matches setting: \(yesNo(store.openedServerURLString != nil && store.openedServerURLString == settings.localFirstServerURLString))",
            "Imported budget count: \(importedBudgetCount)",
            "Selected database file present: \(yesNo(selectedDatabaseURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false))",
            "Selected database bytes: \(fileSize(at: selectedDatabaseURL).map(String.init) ?? "Unknown")",
            "Selected database WAL bytes: \(fileSize(at: sidecarURL(for: selectedDatabaseURL, suffix: "-wal")).map(String.init) ?? "Unknown")",
            "Selected database SHM bytes: \(fileSize(at: sidecarURL(for: selectedDatabaseURL, suffix: "-shm")).map(String.init) ?? "Unknown")",
            "Remote file metadata count: \(store.remoteFilesByFileID.count)",
            "Cached budget count: \(store.cachedBudgets.count)",
            "Cached account budget count: \(store.accountsByBudget.count)",
            "Cached account count: \(store.accountsByBudget.values.reduce(0) { $0 + $1.count })",
            "Cached month budget count: \(store.monthsByBudget.count)",
            "Cached month count: \(store.monthsByBudget.values.reduce(0) { $0 + $1.count })",
            "Cached account transaction feeds: \(store.accountTransactionsByKey.count)",
            "Cached spending feeds: \(store.spendingTransactionsByBudget.count)",
            "Cached category transaction feeds: \(store.categoryTransactionsByKey.count)",
            "Cached report snapshots: \(store.reportsByKey.count)",
            "Pending sync flush active: \(yesNo(store.isFlushingPendingLocalMessages))",
            "Pending sync flush requested again: \(yesNo(store.shouldFlushPendingLocalMessagesAgain))",
            "Pending sync waiter count: \(store.pendingLocalMessageFlushWaiters.count)",
            "",
            "[Pending Transaction Notifications]",
            "Account buckets: \(pendingNotificationCounts.count)",
            "Transaction count: \(pendingNotificationCounts.reduce(0, +))",
            "",
            "[Current Sync Status]",
            "Status available: \(yesNo(syncStatus != nil))",
            "File ID present: \(yesNo(syncStatus?.fileID.isEmpty == false))",
            "Group ID present: \(yesNo(syncStatus?.groupID?.isEmpty == false))",
            "Last attempt: \(timestamp(syncStatus?.lastSyncAttemptAt))",
            "Last success: \(timestamp(syncStatus?.lastSyncedAt))",
            "Last uploaded messages: \(syncStatus?.lastUploadedMessageCount ?? 0)",
            "Last downloaded messages: \(syncStatus?.lastAppliedMessageCount ?? 0)",
            "Pending local messages: \(syncStatus?.pendingLocalMessageCount ?? 0)",
            "Encryption key ID present: \(yesNo(syncStatus?.encryptionKeyID != nil))",
            "Last sync error: \(redactor.redact(syncStatus?.lastError))",
            "",
            "[Local-First Sync Event History]",
            "Total recorded events: \(settings.localFirstSyncDebug.totalEventCount)",
            "Retained events: \(settings.localFirstSyncDebug.recentEvents.count)"
        ]

        if settings.localFirstSyncDebug.recentEvents.isEmpty {
            lines.append("No retained sync events")
        } else {
            for (index, event) in settings.localFirstSyncDebug.recentEvents.enumerated() {
                lines.append(
                    "\(index + 1). \(timestamp(event.date)) | \(event.outcome.rawValue) | \(event.endpoint?.rawValue ?? "local") | pending \(event.pendingBefore)->\(event.pendingAfter) | uploaded \(event.uploadedCount) | downloaded \(event.downloadedCount) | \(redactor.redact(event.message))"
                )
            }
        }

        lines += [
            "",
            "[Background Refresh]",
            "Total schedule attempts: \(settings.backgroundRefreshDebug.totalScheduleAttemptCount)",
            "Retained schedule attempts: \(settings.backgroundRefreshDebug.recentScheduleAttempts.count)",
            "Total wakes: \(settings.backgroundRefreshDebug.totalWakeCount)",
            "Retained runs: \(settings.backgroundRefreshDebug.recentRuns.count)",
            "",
            "[Background Schedule History]"
        ]

        if settings.backgroundRefreshDebug.recentScheduleAttempts.isEmpty {
            lines.append("No retained schedule attempts")
        } else {
            for (index, attempt) in settings.backgroundRefreshDebug.recentScheduleAttempts.enumerated() {
                lines.append(
                    "\(index + 1). \(timestamp(attempt.date)) | \(attempt.succeeded ? "accepted" : "rejected") | earliest \(timestamp(attempt.earliestBeginDate)) | \(redactor.redact(attempt.message))"
                )
            }
        }

        lines += ["", "[Background Run History]"]
        if settings.backgroundRefreshDebug.recentRuns.isEmpty {
            lines.append("No retained background runs")
        } else {
            for (index, run) in settings.backgroundRefreshDebug.recentRuns.enumerated() {
                lines.append(
                    "\(index + 1). woke \(timestamp(run.wakeDate)) | completed \(timestamp(run.completionDate)) | result \(backgroundResult(run.succeeded)) | \(redactor.redact(run.message))"
                )
            }
        }

        lines += [
            "",
            "End of report",
            ""
        ]

        return ActualistDiagnosticReport(
            text: lines.joined(separator: "\n"),
            filename: "Actualist-Diagnostics-\(filenameTimestamp(generatedAt)).txt"
        )
    }

    private static func sensitiveValues(appState: AppState) -> [String] {
        let settings = appState.settings
        let store = appState.localFirstStore
        var values = [
            settings.localFirstServerURLString,
            settings.selectedBudgetID,
            settings.selectedBudgetName,
            settings.selectedLocalFirstFileID,
            settings.selectedLocalFirstGroupID,
            store.openedBudgetID,
            store.openedGroupID,
            store.openedNodeID,
            store.openedServerURLString,
            appState.selectedBudget?.budgetID,
            appState.selectedBudget?.cloudFileId,
            appState.selectedBudget?.groupId,
            appState.selectedBudget?.name
        ].compactMap { $0 }

        if let host = URLComponents(string: settings.localFirstServerURLString)?.host {
            values.append(host)
        }
        for budget in appState.budgets + store.cachedBudgets {
            values.append(contentsOf: [budget.budgetID, budget.cloudFileId, budget.groupId, budget.name].compactMap { $0 })
        }
        for display in store.accountsByBudget.values.joined() {
            values.append(display.account.id)
            values.append(display.account.name)
        }
        return values
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static var hardwareModel: String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return "Unknown"
        }
        let machine = systemInfo.machine
        return withUnsafeBytes(of: machine) { bytes in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return "Unknown"
            }
            return String(cString: baseAddress)
        }
    }

    private static func setupPhase(_ phase: SetupPhase) -> String {
        switch phase {
        case .needsConnection: "needsConnection"
        case .selectingBudget: "selectingBudget"
        case .restoringBudget: "restoringBudget"
        case .ready: "ready"
        }
    }

    private static func connectionStatusLine(_ appState: AppState) -> String {
        if appState.isDemoMode {
            return "demo"
        }
        return connectionStatus(appState.connectionStatus)
    }

    private static func connectionStatus(_ status: ServerConnectionStatus) -> String {
        switch status {
        case .online: "online"
        case .connecting: "connecting"
        case .offline: "offline"
        }
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func applicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private static func backgroundRefreshStatus(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: "available"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
    }

    private static func availableStorageBytes() -> Int64? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return try? applicationSupportURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    private static func fileSize(at url: URL?) -> Int? {
        guard let url else {
            return nil
        }
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private static func sidecarURL(for databaseURL: URL?, suffix: String) -> URL? {
        guard let databaseURL else {
            return nil
        }
        return URL(fileURLWithPath: databaseURL.path + suffix)
    }

    private static func serverTransport(_ serverURLString: String) -> String {
        guard !serverURLString.isEmpty else {
            return "not configured"
        }
        return URLComponents(string: serverURLString)?.scheme?.lowercased() ?? "unknown"
    }

    private static func backgroundResult(_ result: Bool?) -> String {
        switch result {
        case true: "succeeded"
        case false: "failed"
        case nil: "incomplete"
        }
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }

    private static func timestamp(_ date: Date?) -> String {
        guard let date else {
            return "never"
        }
        return diagnosticTimestampFormatter.string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        diagnosticFilenameFormatter.string(from: date)
    }

    private static let diagnosticTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let diagnosticFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter
    }()
}

struct DiagnosticReportRedactor {
    private let sensitiveValues: [String]

    init(sensitiveValues: [String]) {
        self.sensitiveValues = Array(
            Set(
                sensitiveValues
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 4 }
            )
        )
        .sorted { $0.count > $1.count }
    }

    func redact(_ message: String?) -> String {
        guard var result = message?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            return "none"
        }

        for value in sensitiveValues {
            result = result.replacingOccurrences(
                of: value,
                with: "[redacted]",
                options: [.caseInsensitive]
            )
        }

        result = replacing(pattern: #"https?://[^\s]+"#, in: result, with: "[redacted-url]")
        result = replacing(
            pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#,
            in: result,
            with: "[redacted-id]"
        )
        result = replacing(
            pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            in: result,
            with: "[redacted-address]"
        )
        result = replacing(
            pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: [.caseInsensitive],
            in: result,
            with: "[redacted-email]"
        )
        result = replacing(
            pattern: #"(?i)\b(password|token|secret|encryption[-_ ]?key)\s*[:=]\s*[^\s,;]+"#,
            in: result,
            with: "$1=[redacted]"
        )
        result = replacing(
            pattern: #"(?:file://)?/(?:[^\s/:]+/)+[^\s:]+"#,
            in: result,
            with: "[redacted-path]"
        )
        result = replacing(
            pattern: #"(?:[$€£¥]\s*[-+]?\d[\d,.]*|[-+]?\d[\d,.]*\s*(?:USD|EUR|GBP|JPY))"#,
            options: [.caseInsensitive],
            in: result,
            with: "[redacted-amount]"
        )
        result = result.replacingOccurrences(of: "\r\n", with: " ")
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")
        return result
    }

    private func replacing(
        pattern: String,
        options: NSRegularExpression.Options = [],
        in value: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}
