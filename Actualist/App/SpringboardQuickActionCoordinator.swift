import UIKit

enum SpringboardQuickAction {
    static let typePrefix = "com.sporez.actualist.quick-action."
    static let actions = WidgetQuickActions.defaults

    static func action(for type: String) -> WidgetQuickAction? {
        guard type.hasPrefix(typePrefix) else {
            return nil
        }
        let rawValue = String(type.dropFirst(typePrefix.count))
        guard let action = WidgetQuickAction(rawValue: rawValue), actions.contains(action) else {
            return nil
        }
        return action
    }

    static func type(for action: WidgetQuickAction) -> String {
        typePrefix + action.rawValue
    }
}

@MainActor
final class SpringboardQuickActionCoordinator {
    static let shared = SpringboardQuickActionCoordinator()

    private weak var appState: AppState?
    private var pendingAction: WidgetQuickAction?

    func configure(appState: AppState) {
        self.appState = appState
        guard let pendingAction else {
            return
        }
        self.pendingAction = nil
        route(pendingAction, using: appState)
    }

    @discardableResult
    func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        handle(type: shortcutItem.type)
    }

    @discardableResult
    func handle(type: String) -> Bool {
        guard let action = SpringboardQuickAction.action(for: type) else {
            return false
        }
        guard let appState else {
            pendingAction = action
            return true
        }
        route(action, using: appState)
        return true
    }

    private func route(_ action: WidgetQuickAction, using appState: AppState) {
        WidgetDeepLinkRouter.handle(
            WidgetDeepLink.url(.quickAction(action)),
            appState: appState
        )
    }
}

@MainActor
final class ActualistApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = ActualistSceneDelegate.self
        return configuration
    }
}

@MainActor
final class ActualistSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem else {
            return
        }
        _ = SpringboardQuickActionCoordinator.shared.handle(shortcutItem)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(SpringboardQuickActionCoordinator.shared.handle(shortcutItem))
    }
}
