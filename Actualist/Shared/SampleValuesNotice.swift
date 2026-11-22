import SwiftUI

/// Tells the viewer that Use Sample Values is on, so the budget names and
/// amounts on screen are made up. The real names stay hidden.
enum SampleValuesNotice {
    static let subtitle: LocalizedStringResource = "Sample Values on"
    static let pickerFooter: LocalizedStringResource =
        "Use Sample Values is on, so budget names and amounts are made up. Turn it off in Settings → Privacy & Notifications."
}

extension View {
    /// The navigation subtitle a main screen shows while Sample Values is on.
    /// The modifier stays applied when the mode changes, so the screen keeps
    /// its identity and state.
    func sampleValuesSubtitle() -> some View {
        modifier(SampleValuesSubtitleModifier())
    }
}

/// For a custom principal toolbar title, which replaces the system subtitle.
struct SampleValuesTitleCaption: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.settings.randomizedDisplayValuesEnabled {
            Text(SampleValuesNotice.subtitle)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
    }
}

/// The footer of a budget picker while Sample Values is on.
struct SampleValuesPickerFooter: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.settings.randomizedDisplayValuesEnabled {
            Text(SampleValuesNotice.pickerFooter)
        }
    }
}

private struct SampleValuesSubtitleModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.navigationSubtitle(
            appState.settings.randomizedDisplayValuesEnabled
                ? Text(SampleValuesNotice.subtitle)
                : Text(verbatim: "")
        )
    }
}
