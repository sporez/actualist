import Foundation

/// Compact relative age ("just now", "5m ago", "3h ago", "2d ago") for sync
/// and connection captions.
enum CompactAgeText {
    static func text(since date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 {
            return "just now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 1 {
            return "<1m ago"
        }
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }
}
