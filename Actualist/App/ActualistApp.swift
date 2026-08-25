import AppIntents
import BackgroundTasks
import SwiftUI
import UserNotifications

enum AppSwitcherSnapshotPolicy {
    static func shouldCover(
        mode: AppSwitcherPrivacyMode,
        scenePhase: ScenePhase,
        isAppInitiatedSystemUISuppressed: Bool
    ) -> Bool {
        switch mode {
        case .off:
            false
        case .whenBackgrounded:
            scenePhase == .background
        case .always:
            !isAppInitiatedSystemUISuppressed && scenePhase != .active
        }
    }
}

@main
struct ActualistApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        BackgroundTransactionRefreshCoordinator.shared.configure(appState: appState)
        let session = ShortcutsBudgetSession(appState: appState)
        AppDependencyManager.shared.add { session }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .appSwitcherPrivacyProtected()
                .environment(appState)
                .preferredColorScheme(appState.settings.theme.colorScheme)
                .onAppear {
                    BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: appState)
                }
                .task {
                    await appState.prepareBackgroundTransactionNotifications()
                    await appState.beginForegroundSession()
                    if let command = SimulatorLaunchCommand.fromProcessInfo() {
                        await SimulatorLaunchApplier.apply(command, to: appState)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        appState.clearAppInitiatedSystemUIPresentationSuppression()
                        Task {
                            await appState.beginForegroundSession()
                        }
                    } else if phase == .background {
                        appState.endForegroundSession()
                        BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: appState)
                    }
                }
        }
    }
}

private struct AppSwitcherPrivacyProtectionModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.overlay {
            if shouldCover {
                AppSwitcherPrivacyCover(theme: appState.settings.theme)
                    .transition(.identity)
            }
        }
    }

    private var shouldCover: Bool {
        AppSwitcherSnapshotPolicy.shouldCover(
            mode: appState.settings.appSwitcherPrivacyMode,
            scenePhase: scenePhase,
            isAppInitiatedSystemUISuppressed: appState.isAppSwitcherCoverSuppressedForSystemUI
        )
    }
}

private struct AppSwitcherPrivacyAwareDragIndicatorModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.presentationDragIndicator(shouldCover ? .hidden : .visible)
    }

    private var shouldCover: Bool {
        AppSwitcherSnapshotPolicy.shouldCover(
            mode: appState.settings.appSwitcherPrivacyMode,
            scenePhase: scenePhase,
            isAppInitiatedSystemUISuppressed: appState.isAppSwitcherCoverSuppressedForSystemUI
        )
    }
}

extension View {
    // Presented views have separate hosting layers.
    func appSwitcherPrivacyProtected() -> some View {
        modifier(AppSwitcherPrivacyProtectionModifier())
    }

    // The system-owned grabber sits above the presented content.
    func appSwitcherPrivacyAwareDragIndicator() -> some View {
        modifier(AppSwitcherPrivacyAwareDragIndicatorModifier())
    }
}

private struct AppSwitcherPrivacyCover: View {
    let theme: ActualistThemeOption

    var body: some View {
        let palette = ActualistTheme.palette(for: theme)

        ZStack {
            palette.background
                .ignoresSafeArea()

            Text("Actualist")
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.primaryText)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

final class BackgroundTransactionRefreshCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BackgroundTransactionRefreshCoordinator()

    static let taskIdentifier = "com.sporez.actualist.transactions.refresh"
    private let requestedInterval: TimeInterval = 60 * 60
    private weak var appState: AppState?
    private var didRegisterTask = false

    func configure(appState: AppState) {
        self.appState = appState
        UNUserNotificationCenter.current().delegate = self

        guard !didRegisterTask else {
            return
        }

        didRegisterTask = true
        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(refreshTask)
        }
        Task { @MainActor in
            appState.updateApplicationBadge()
            appState.recordBackgroundRefreshScheduleAttempt(
                succeeded: didRegister,
                earliestBeginDate: nil,
                message: didRegister ? "Registered background task" : "Failed to register background task"
            )
        }
    }

    @MainActor
    func scheduleIfNeeded(for appState: AppState) {
        self.appState = appState
        if let skipReason = scheduleSkipReason(for: appState) {
            cancel()
            appState.recordBackgroundRefreshScheduleAttempt(
                succeeded: false,
                earliestBeginDate: nil,
                message: skipReason
            )
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        let earliestBeginDate = Date(timeIntervalSinceNow: requestedInterval)
        request.earliestBeginDate = earliestBeginDate
        cancel()

        do {
            try BGTaskScheduler.shared.submit(request)
            appState.recordBackgroundRefreshScheduleAttempt(
                succeeded: true,
                earliestBeginDate: earliestBeginDate,
                message: "Scheduled background refresh"
            )
        } catch {
            appState.recordBackgroundRefreshScheduleAttempt(
                succeeded: false,
                earliestBeginDate: earliestBeginDate,
                message: "Schedule failed: \(error.localizedDescription)"
            )
        }
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    @MainActor
    private func scheduleSkipReason(for appState: AppState) -> String? {
        var reasons: [String] = []
        if !appState.settings.backgroundTransactionRefreshEnabled {
            reasons.append("alerts disabled")
        }
        if appState.settings.selectedBudgetID == nil {
            reasons.append("no selected budget")
        }
        if !appState.hasSyncCredentials {
            reasons.append("sync credentials missing")
        }

        guard !reasons.isEmpty else {
            return nil
        }
        return "Skipped schedule: \(reasons.joined(separator: ", "))"
    }

    private func handle(_ task: BGAppRefreshTask) {
        if let appState {
            Task { @MainActor in
                scheduleIfNeeded(for: appState)
            }
        }

        var refresh: Task<Void, Never>?
        task.expirationHandler = {
            refresh?.cancel()
        }

        refresh = Task { [weak self] in
            guard let appState = self?.appState else {
                task.setTaskCompleted(success: false)
                return
            }

            let success = await appState.performBackgroundTransactionRefresh()
            task.setTaskCompleted(success: success)
        }
    }

    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let budgetID = userInfo["budgetID"] as? String,
              let appState else {
            return
        }

        await appState.routeToSpendingFromNotification(budgetID: budgetID)
    }
}
