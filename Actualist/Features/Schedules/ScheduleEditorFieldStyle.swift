import SwiftUI

/// Input-surface treatment for the schedule editor's plain text fields so they
/// read as editable inputs. Matches the app's rounded control-surface
/// precedent (the search field in `TransactionBatchCategoryPickerView`).
struct ScheduleEditorFieldStyle: ViewModifier {
    @Environment(\.actualistDensity) private var density

    func body(content: Content) -> some View {
        content
            .font(ActualistTypography.body(for: density))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func scheduleEditorFieldStyle() -> some View {
        modifier(ScheduleEditorFieldStyle())
    }
}
