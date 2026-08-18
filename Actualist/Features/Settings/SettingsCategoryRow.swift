import SwiftUI

/// A reusable root-category row label for the Settings directory.
///
/// This is a label only — it is meant to live inside a native `NavigationLink`
/// (or `List`/`Form` row) so SwiftUI owns chevrons, selection states, hit
/// targets, and Dynamic Type sizing.
struct SettingsCategoryRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var subtitleColor: Color?

    var body: some View {
        Label {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(subtitleColor ?? ActualistTheme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(ActualistTheme.accent)
        }
    }
}
