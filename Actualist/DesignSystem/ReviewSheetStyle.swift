import SwiftUI

/// Opaque review surfaces use the same palette and border as Apply Template.
/// Native navigation and action buttons provide their own Liquid Glass.
extension View {
    func actualistReviewCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ActualistTheme.separator, lineWidth: 1))
    }
}

struct ReviewSheetContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
    }
}

/// Pins the review action bar below the sheet's scroll content.
///
/// Invariant: `.safeAreaBar(edge: .bottom)` does not reliably inset scroll
/// content when the sheet runs inside a `NavigationStack` presented with
/// `.presentationSizing(.page...)`, letting scrolled rows render underneath
/// the bar. Composing the scroll area and `ReviewSheetActions` as
/// `VStack(spacing: 0)` siblings is plain layout, so the scroll area
/// geometrically ends above the bar in every presentation context; the
/// opaque `ActualistTheme.background` keeps content from showing through or
/// under the bar; and keyboard avoidance lifts the whole stack, so the bar
/// stays above the keyboard while the scroll area shrinks and remains
/// reachable. This is the composition proven by `TransactionBatchReviewSheet`
/// and matches the rendered appearance of the
/// `BudgetTemplateConfirmationSheet` master.
extension View {
    func reviewSheetBottomBar<Actions: View>(
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        modifier(ReviewSheetBottomBarModifier(actions: actions))
    }
}

private struct ReviewSheetBottomBarModifier<Actions: View>: ViewModifier {
    @ViewBuilder let actions: () -> Actions

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            ReviewSheetActions { actions() }
        }
        .background(ActualistTheme.background)
    }
}

struct ReviewSheetHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(ActualistTheme.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

struct ReviewSheetActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            content
        }
        .font(.subheadline.weight(.semibold))
        .controlSize(.small)
        .frame(maxWidth: 520)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

struct ReviewSummaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let value: String
    let symbol: String
    var valueColor: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(width: 24, height: 24)
                .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                Text(title)
                    .foregroundStyle(ActualistTheme.secondaryText)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                }
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(valueColor ?? ActualistTheme.primaryText)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
    }
}
