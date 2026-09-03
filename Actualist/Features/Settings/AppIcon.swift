import UIKit

enum AppIcon: String, CaseIterable, Identifiable {
    case `default`
    case coin
    case purple
    case blue
    case orange

    var id: String { rawValue }

    var alternateIconName: String? {
        switch self {
        case .default: nil
        case .coin: "coin"
        case .purple: "icon_purple"
        case .blue: "icon_blue"
        case .orange: "icon_orange"
        }
    }

    // App icons cannot be loaded with UIImage(named:), so previews use ordinary image sets.
    var previewImageName: String {
        switch self {
        case .default: "AppIconPreviewDefault"
        case .coin: "AppIconPreviewCoin"
        case .purple: "AppIconPreviewPurple"
        case .blue: "AppIconPreviewBlue"
        case .orange: "AppIconPreviewOrange"
        }
    }

    var title: String {
        switch self {
        case .default: "Default"
        case .coin: "Coin"
        case .purple: "Purple"
        case .blue: "Blue"
        case .orange: "Orange"
        }
    }

    @MainActor
    static func current() -> AppIcon {
        current(in: .shared)
    }

    @MainActor
    static func current(in application: UIApplication) -> AppIcon {
        let name = application.alternateIconName
        return allCases.first { $0.alternateIconName == name } ?? .default
    }
}
