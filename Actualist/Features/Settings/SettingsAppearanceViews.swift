import SwiftUI

struct ThemePreviewStrip: View {
    let theme: ActualistThemeOption
    /// Names the strip when two show at once.
    var label: String?

    var body: some View {
        let palette = theme.palette

        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ActualistTheme.secondaryText)
                Spacer(minLength: 8)
            }
            ThemeSwatch(color: palette.background)
            ThemeSwatch(color: palette.surface)
            ThemeSwatch(color: palette.elevatedSurface)
            ThemeSwatch(color: palette.accent)
            ThemeSwatch(color: palette.positive)
            ThemeSwatch(color: palette.warning)
            ThemeSwatch(color: palette.danger)
            ThemeSwatch(color: palette.neutral)
        }
        .padding(.vertical, 4)
    }
}

struct AppIconPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SettingsViewModel

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "App Icon")
            VStack(spacing: 16) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AppIcon.allCases) { icon in
                        Button {
                            Task { await viewModel.setAppIcon(icon) }
                        } label: {
                            AppIconChoice(
                                icon: icon,
                                isSelected: viewModel.selectedAppIcon == icon
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let error = viewModel.appIconError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .actualistReviewCard()
        }
        .reviewSheetBottomBar {
            ReviewSheetPrimaryButton {
                dismiss()
            } label: {
                Text("Done")
            }
        }
        .reviewSheetPresentation(detents: [.medium, .large], appState: appState)
    }
}

private struct AppIconChoice: View {
    let icon: AppIcon
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            AppIconThumbnail(icon: icon, size: 72)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected ? ActualistTheme.accent : .clear,
                            lineWidth: 3
                        )
                }

            Text(icon.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? ActualistTheme.primaryText : ActualistTheme.secondaryText)
        }
    }
}

struct AppIconThumbnail: View {
    let icon: AppIcon
    let size: CGFloat

    var body: some View {
        let radius = size * 0.2237

        Group {
            if let image = UIImage(named: icon.previewImageName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(ActualistTheme.elevatedSurface)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func settingsSectionChrome(isSidebar: Bool = false) -> some View {
        self
            .listRowBackground(isSidebar ? nil : ActualistTheme.surface)
            .listRowSeparatorTint(ActualistTheme.separator)
    }

    func settingsRowChrome() -> some View {
        self
            .listRowBackground(ActualistTheme.surface)
            .listRowSeparatorTint(ActualistTheme.separator)
    }
}

private struct ThemeSwatch: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
    }
}
