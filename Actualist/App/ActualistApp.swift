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

    @MainActor
    static func shouldCover(appState: AppState, scenePhase: ScenePhase) -> Bool {
        shouldCover(
            mode: appState.settings.appSwitcherPrivacyMode,
            scenePhase: scenePhase,
            isAppInitiatedSystemUISuppressed: appState.isAppSwitcherCoverSuppressedForSystemUI
        )
    }
}

@main
struct ActualistApp: App {
    @UIApplicationDelegateAdaptor(ActualistApplicationDelegate.self) private var applicationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState
    private let simulatorLaunchCommand: SimulatorLaunchCommand?

    init() {
        #if DEBUG
        let appState = SyntheticCredentialFaultHarness.make(arguments: ProcessInfo.processInfo.arguments)
            ?? AppState()
        #else
        let appState = AppState()
        #endif
        PortableExportFiles().sweepStale()
        #if DEBUG
        let simulatorLaunchCommand = SimulatorLaunchCommand.fromProcessInfo()
        #else
        let simulatorLaunchCommand: SimulatorLaunchCommand? = nil
        #endif
        if let simulatorLaunchCommand {
            SimulatorLaunchApplier.prepareDemoReplacementIfNeeded(
                simulatorLaunchCommand,
                appState: appState
            )
        }
        _appState = State(initialValue: appState)
        self.simulatorLaunchCommand = simulatorLaunchCommand
        SpringboardQuickActionCoordinator.shared.configure(appState: appState)
        BackgroundTransactionRefreshCoordinator.shared.configure(appState: appState)
        WidgetSnapshotCoordinator.shared.configure(appState: appState)
        BudgetCalendarCoordinator.shared.configure(appState: appState)
        let session = ShortcutsBudgetSession(appState: appState)
        AppDependencyManager.shared.add { session }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .appSwitcherPrivacyProtected(using: appState)
                .preferredColorScheme(appState.settings.theme.colorScheme)
                .onAppear {
                    BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: appState)
                }
                .onOpenURL { url in
                    WidgetDeepLinkRouter.handle(url, appState: appState)
                }
                .task {
                    LaunchSignpost.event(LaunchStage.foregroundSessionStart)
                    BudgetCalendarCoordinator.shared.beginForeground()
                    #if DEBUG
                    await SyntheticCredentialFaultHarness.prepareCacheIfRequested(
                        arguments: ProcessInfo.processInfo.arguments, appState: appState
                    )
                    #endif
                    await appState.beginForegroundSession()
                    if let command = simulatorLaunchCommand {
                        await SimulatorLaunchApplier.apply(command, to: appState)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
                ) { _ in
                    appState.refreshCredentialAvailability()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        BudgetCalendarCoordinator.shared.beginForeground()
                        appState.clearAppInitiatedSystemUIPresentationSuppression()
                        #if DEBUG
                        // The synthetic cached fixture must finish installation
                        // before launch restoration starts in the window task.
                        if !ProcessInfo.processInfo.arguments.contains("-actualist-test-credential-session") {
                            Task { await appState.beginForegroundSession() }
                        }
                        #else
                        Task {
                            await appState.beginForegroundSession()
                        }
                        #endif
                    } else if phase == .background {
                        BudgetCalendarCoordinator.shared.endForeground()
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
        AppSwitcherSnapshotPolicy.shouldCover(appState: appState, scenePhase: scenePhase)
    }
}

private struct AppSwitcherPrivacyAwareDragIndicatorModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.presentationDragIndicator(shouldCover ? .hidden : .visible)
    }

    private var shouldCover: Bool {
        AppSwitcherSnapshotPolicy.shouldCover(appState: appState, scenePhase: scenePhase)
    }
}

extension View {
    // Presented views have separate hosting layers.
    func appSwitcherPrivacyProtected(using appState: AppState) -> some View {
        modifier(AppSwitcherPrivacyProtectionModifier())
            .environment(appState)
    }

    // The system-owned grabber sits above the presented content.
    func appSwitcherPrivacyAwareDragIndicator() -> some View {
        modifier(AppSwitcherPrivacyAwareDragIndicatorModifier())
    }
}

private struct AppSwitcherPrivacyCover: View {
    let theme: ActualistThemeOption

    var body: some View {
        let palette = theme.palette

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

/// Completes a `BGAppRefreshTask` from an unstructured task. The system owns
/// the task object and delivers it on the registration queue; we only call
/// `setTaskCompleted` once after the main-actor refresh finishes.
///
/// Invariant: the wrapped task is touched only by `complete(success:)`, which
/// the single unstructured task in `handle(_:)` calls exactly once, after
/// `refresh` has finished or been cancelled by the expiration handler. The
/// struct is never stored or shared, so there is no concurrent access.
private struct BackgroundRefreshTaskCompletion: @unchecked Sendable {
    let task: BGAppRefreshTask

    func complete(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class BackgroundTransactionRefreshCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BackgroundTransactionRefreshCoordinator()

    static let taskIdentifier = AppInstallationIdentity.current.backgroundTaskIdentifier
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
        // This launch closure inherits MainActor; nil would deliver it on a
        // background queue and trap at the Swift 6 isolation check.
        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: .main
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

    /// Cancels the scheduled task only when neither toggle wants background
    /// work; otherwise (re)schedules, so disabling alerts while background
    /// bank sync is on keeps the task alive.
    @MainActor
    func cancelOrReschedule(for appState: AppState) {
        if scheduleSkipReason(for: appState) != nil {
            cancel()
        } else {
            scheduleIfNeeded(for: appState)
        }
    }

    @MainActor
    private func scheduleSkipReason(for appState: AppState) -> String? {
        var reasons: [String] = []
        // One background task serves alerts and bank sync independently.
        if !appState.settings.wantsBackgroundAppRefresh {
            reasons.append("alerts and bank sync disabled")
        }
        if appState.settings.selectedBudgetID == nil {
            reasons.append("no selected budget")
        }
        if appState.credentialAvailability == .absent {
            reasons.append("sync credentials missing")
        }

        guard !reasons.isEmpty else {
            return nil
        }
        return "Skipped schedule: \(reasons.joined(separator: ", "))"
    }

    nonisolated private func handle(_ task: BGAppRefreshTask) {
        let completion = BackgroundRefreshTaskCompletion(task: task)
        let refresh = Task { [weak self] in
            await self?.runBackgroundRefresh() ?? false
        }
        task.expirationHandler = {
            refresh.cancel()
        }
        Task {
            let success = await refresh.value
            completion.complete(success: success)
        }
    }

    private func runBackgroundRefresh() async -> Bool {
        guard let appState else {
            return false
        }
        scheduleIfNeeded(for: appState)
        return await appState.performBackgroundTransactionRefresh()
    }

    /// Handles the notification tap through the completion-handler
    /// requirement on purpose. The async spelling cannot be MainActor-
    /// isolated: the SDK's `UNUserNotificationCenter` and
    /// `UNNotificationResponse` are not Sendable, so Swift 6 rejects an
    /// isolated witness. But a `nonisolated` async witness returns on the
    /// cooperative pool, and iOS performs the notification-response
    /// completion (including the background-transition snapshot update)
    /// on that thread — UIKit then aborts with an uncaught
    /// NSAssertionHandler exception in
    /// `_performBlockAfterCATransactionCommitSynchronizes:` when the
    /// notification was tapped while the app was backgrounded. Routing on
    /// the main actor and invoking the completion handler there keeps the
    /// whole response completion on the main thread. Same class of fix as
    /// delivering the BGTask launch handler on `.main`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let budgetID = response.notification.request.content.userInfo["budgetID"] as? String
        // Invariant: the system block is invoked exactly once, from the main
        // actor, after routing finishes, and is not used anywhere else; the
        // unsafe binding only suspends the Sendable check across that hop.
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            await routeNotification(budgetID: budgetID)
            completion()
        }
    }

    private func routeNotification(budgetID: String?) async {
        guard let budgetID, let appState else {
            return
        }
        await appState.routeToSpendingFromNotification(budgetID: budgetID)
    }
}
