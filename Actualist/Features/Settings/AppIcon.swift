import UIKit

/// The selectable app icons. The primary Icon Composer icon (`default.icon`) has a `nil`
/// alternate name; the others map to the `.icon` files registered as alternate app icons
/// via `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`.
enum AppIcon: String, CaseIterable, Identifiable {
    case `default`
    case coin
    case purple
    case blue
    case orange

    var id: String { rawValue }

    /// The alternate icon name passed to `setAlternateIconName`. `nil` selects the primary icon.
    var alternateIconName: String? {
        switch self {
        case .default: nil
        case .coin: "coin"
        case .purple: "icon_purple"
        case .blue: "icon_blue"
        case .orange: "icon_orange"
        }
    }

    /// Asset-catalog image used to render the option's preview thumbnail.
    ///
    /// iOS provides no public API to load a rendered app icon (primary or alternate) as an
    /// image — `UIImage(named:)` returns `nil` for icon assets on iOS 18+ — so the picker
    /// shows dedicated preview image sets bundled in the asset catalog.
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

    /// The icon currently set on the running app.
    static func current(in application: UIApplication = .shared) -> AppIcon {
        let name = application.alternateIconName
        return allCases.first { $0.alternateIconName == name } ?? .default
    }
}
