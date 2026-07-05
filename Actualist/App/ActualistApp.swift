import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct ActualistApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        BackgroundTransactionRefreshCoordinator.shared.configure(appState: appState)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: appState)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else {
                        return
                    }

                    BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: appState)
                }
        }
    }
}

final class BackgroundTransactionRefreshCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BackgroundTransactionRefreshCoordinator()

    static let taskIdentifier = "com.sporez.actualist.localfirst.transactions.refresh"
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
        if !appState.canUseAPI {
            reasons.append("API credentials missing")
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

        let refresh = Task { [weak self] in
            guard let appState = self?.appState else {
                task.setTaskCompleted(success: false)
                return
            }

            let success = await appState.performBackgroundTransactionRefresh()
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            refresh.cancel()
        }
    }

    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let budgetID = userInfo["budgetID"] as? String,
              let accountID = userInfo["accountID"] as? String,
              let appState else {
            return
        }

        await appState.routeToAccountFromNotification(budgetID: budgetID, accountID: accountID)
    }
}
