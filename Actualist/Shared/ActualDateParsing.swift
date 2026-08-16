import Foundation

extension String {
    /// Parses an Actual `yyyy-MM-dd` date string into a `Date`.
    var actualDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: self)
    }

    /// Returns the `yyyy-MM` prefix of an Actual date string, or nil if too short.
    var actualYearMonth: String? {
        guard count >= 7 else {
            return nil
        }

        return String(prefix(7))
    }
}
