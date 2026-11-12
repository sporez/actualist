import Foundation

extension String {
    /// Whether this text contains `query`, ignoring case and diacritics in the
    /// current locale. The caller trims the query and decides what an empty one means.
    func matchesSearch(_ query: String) -> Bool {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .contains(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
    }
}
