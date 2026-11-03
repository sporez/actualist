import SwiftUI
import UIKit

/// Applies the appearance's color scheme to the app's windows.
///
/// `preferredColorScheme` sets the style on the hosting view controllers (the
/// root and each presented one). Going from a scheme back to `nil` leaves that
/// style in place until relaunch, so a fixed dark theme on a light phone stayed
/// dark after Match System turned on (iOS 26.3 simulator). When the scheme
/// becomes `nil`, this clears the style so every controller follows the system.
private struct AppearanceColorSchemeModifier: ViewModifier {
    let preferredColorScheme: ColorScheme?

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferredColorScheme)
            .onChange(of: preferredColorScheme) { _, scheme in
                guard scheme == nil else { return }
                Self.followSystemInterfaceStyle()
            }
    }

    private static func followSystemInterfaceStyle() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.overrideUserInterfaceStyle = .unspecified
                    controller = current.presentedViewController
                }
            }
        }
    }
}

extension View {
    func appearanceColorScheme(_ appearance: ActualistAppearance) -> some View {
        modifier(AppearanceColorSchemeModifier(preferredColorScheme: appearance.preferredColorScheme))
    }
}
