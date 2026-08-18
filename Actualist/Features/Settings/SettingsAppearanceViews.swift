import SwiftUI

struct ThemePreviewStrip: View {
    let theme: ActualistThemeOption

    var body: some View {
        let palette = ActualistTheme.palette(for: theme)

        HStack(spacing: 8) {
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
    @State private var toastTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AppIcon.allCases) { icon in
                        Button {
                            recordDeveloperUnlockTap()
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
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ActualistTheme.background)
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if let developerUnlockToastMessage = appState.developerUnlockToastMessage {
                    Text(developerUnlockToastMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(ActualistTheme.elevatedSurface, in: Capsule())
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .appSwitcherPrivacyProtected()
        .onDisappear {
            toastTask?.cancel()
        }
    }

    private func recordDeveloperUnlockTap() {
        if let message = appState.recordDeveloperUnlockTap() {
            toastTask = DeveloperUnlockToast.present(
                message,
                on: appState,
                replacing: toastTask
            )
        }
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
    func settingsSectionChrome() -> some View {
        self
            .listRowBackground(ActualistTheme.surface)
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
