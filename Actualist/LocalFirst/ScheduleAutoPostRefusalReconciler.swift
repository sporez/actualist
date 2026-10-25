import Foundation

/// Decides which recorded automatic-post refusals still describe the schedule
/// as it is now. A refusal belongs to one occurrence of one schedule: it ends
/// when that schedule is gone, completed or paid, or its next date moved (a
/// post, a skip or an edit here or on another device).
enum ScheduleAutoPostRefusalReconciler {
    static func retained(
        _ refusals: [ScheduleAutoPostRefusal],
        in schedules: LoadedSchedules
    ) -> [ScheduleAutoPostRefusal] {
        refusals.filter { refusal in
            guard let detail = schedules.detail(id: refusal.scheduleID),
                  !detail.completed,
                  detail.effectiveNextDate == refusal.occurrenceDayID else {
                return false
            }
            return detail.status == .due || detail.status == .missed
        }
    }
}
