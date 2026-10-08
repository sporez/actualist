import SwiftUI

/// Presentation chrome shared by gold-style review/input sheets: detents,
/// privacy-aware grabber, opaque themed background and app-switcher privacy.
/// Accessibility text sizes always get the large detent so content and the
/// floating action bar never compete for a short sheet.
extension View {
    func reviewSheetPresentation(
        detents: Set<PresentationDetent> = [.large],
        appState: AppState
    ) -> some View {
        modifier(ReviewSheetPresentationModifier(detents: detents))
            .appSwitcherPrivacyAwareDragIndicator()
            .presentationBackground(ActualistTheme.background)
            .appSwitcherPrivacyProtected(using: appState)
    }
}

private struct ReviewSheetPresentationModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let detents: Set<PresentationDetent>

    func body(content: Content) -> some View {
        content.presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : detents)
    }
}

/// A surface card that stacks form rows with consistent spacing.
struct ReviewFormCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .actualistReviewCard()
    }
}

/// A titled input row: caption above, field-style control below. Wraps
/// naturally at accessibility sizes because the title sits above the control.
struct ReviewFormFieldRow<Field: View>: View {
    let title: String
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            field
        }
    }
}

/// A switch row. The label wraps and the switch stays trailing.
struct ReviewFormToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(ActualistTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled segmented control row.
struct ReviewFormSegmentedRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        ReviewFormFieldRow(title: title) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// Centered title (and optional subtitle) as the first row of a `List`/`Form`
/// based review sheet. Used where List features (swipe delete, reordering,
/// refresh) must be kept; the row is chrome-free like `ReviewSheetHeader`.
struct ReviewSheetListHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        ReviewSheetHeader(title: title, subtitle: subtitle)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
    }
}

extension View {
    /// Themed `List`/`Form` surface for review sheets: opaque background and
    /// palette text/tint. Sections stay inset cards via `settingsSectionChrome`.
    func reviewSheetList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
    }
}
