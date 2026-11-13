import Foundation

extension String {
    /// Actual's `getNormalisedString` (packages/loot-core/src/shared/normalisation.ts):
    /// lowercased, ł ø ß œ folded to l o ss oe, decomposed, diacritics removed. Never trimmed.
    var actualNormalised: String {
        let folded = lowercased()
            .replacingOccurrences(of: "ł", with: "l", options: .literal)
            .replacingOccurrences(of: "ø", with: "o", options: .literal)
            .replacingOccurrences(of: "ß", with: "ss", options: .literal)
            .replacingOccurrences(of: "œ", with: "oe", options: .literal)
        var result = String.UnicodeScalarView()
        for scalar in folded.decomposedStringWithCanonicalMapping.unicodeScalars
        where !scalar.properties.isDiacritic {
            result.append(scalar)
        }
        return String(result)
    }
}
