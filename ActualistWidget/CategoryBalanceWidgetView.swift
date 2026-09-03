import SwiftUI
import WidgetKit

struct CategoryBalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: CategoryBalanceEntry

    var body: some View {
        Group {
            switch entry.state {
            case .placeholder, .ready:
                categoryRows
            case .needsCategories:
                emptyState(
                    icon: "list.bullet.rectangle.portrait",
                    title: "Choose categories",
                    detail: "Edit this widget to select the balances you want to see."
                )
            case .needsApp:
                emptyState(
                    icon: "arrow.clockwise",
                    title: "Open Actualist",
                    detail: "Refresh your current budget to update this widget."
                )
            case .categoriesUnavailable:
                emptyState(
                    icon: "slider.horizontal.3",
                    title: "Update categories",
                    detail: "Edit this widget to choose categories from the current budget."
                )
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.09, blue: 0.17),
                    Color(red: 0.06, green: 0.06, blue: 0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var categoryRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.rows.enumerated()), id: \.element.id) { index, row in
                Link(destination: WidgetDeepLink.url(.category(id: row.id, month: row.month))) {
                    categoryRow(row)
                }
                if index < entry.rows.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 1)
                        .padding(.leading, 14)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .redacted(reason: entry.state == .placeholder ? .placeholder : [])
    }

    private func categoryRow(_ row: WidgetCategoryBalanceRow) -> some View {
        HStack(spacing: 10) {
            Text(row.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 6)

            Text(row.formattedAvailable)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(amountForeground(for: row.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(amountBackground(for: row.tone), in: Capsule())
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(row.formattedAvailable) available")
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(red: 0.67, green: 0.55, blue: 0.96))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.64))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rowHeight: CGFloat {
        family == .systemLarge ? 42 : 47
    }

    private func amountBackground(for tone: WidgetAmountTone) -> Color {
        switch tone {
        case .positive:
            Color(red: 0.53, green: 0.80, blue: 0.22)
        case .zero:
            Color.white.opacity(0.16)
        case .negative:
            Color(red: 0.82, green: 0.24, blue: 0.31)
        }
    }

    private func amountForeground(for tone: WidgetAmountTone) -> Color {
        switch tone {
        case .positive:
            Color.black.opacity(0.76)
        case .zero, .negative:
            .white
        }
    }

    private var accessibilityLabel: String {
        entry.budgetName.isEmpty
            ? "Category balances"
            : "Category balances for \(entry.budgetName)"
    }
}
