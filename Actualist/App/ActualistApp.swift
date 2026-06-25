import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct ActualistApp: App {
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
        }
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
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(refreshTask)
        }
    }

    @MainActor
    func scheduleIfNeeded(for appState: AppState) {
        self.appState = appState
        guard appState.settings.backgroundTransactionRefreshEnabled,
              appState.settings.selectedBudgetID != nil,
              appState.canUseAPI else {
            cancel()
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: requestedInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
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
