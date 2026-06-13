import Foundation
import SwiftUI

struct CategoryNameParts {
    let emoji: String?
    let name: String
}

extension String {
    var actualistCategoryNameParts: CategoryNameParts {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isActualistLeadingEmoji else {
            return CategoryNameParts(emoji: nil, name: trimmed)
        }

        let name = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        return CategoryNameParts(emoji: String(first), name: name.isEmpty ? trimmed : name)
    }
}

extension Font {
    static func actualistEmoji(size: CGFloat) -> Font {
        .custom("Apple Color Emoji", fixedSize: size)
    }
}

private extension Character {
    var isActualistLeadingEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation ||
                scalar.value == 0xFE0F ||
                scalar.properties.generalCategory == .otherSymbol
        }
    }
}
