import UIKit

/// Immediate presentation feedback, including actions that dismiss their host
/// in the same update. No view or workflow state is owned here.
@MainActor
enum ActualistHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func editorOpened() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
    }
}
