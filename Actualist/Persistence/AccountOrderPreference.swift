import Foundation

enum AccountOrderPreference {
    static func ordered<Element: Identifiable>(
        _ elements: [Element],
        preferredIDs: [String]
    ) -> [Element] where Element.ID == String {
        guard !preferredIDs.isEmpty else {
            return elements
        }

        var elementsByID: [String: Element] = [:]
        for element in elements {
            elementsByID[element.id] = element
        }

        var seenIDs = Set<String>()
        var orderedElements: [Element] = []
        for id in preferredIDs where !seenIDs.contains(id) {
            guard let element = elementsByID[id] else {
                continue
            }
            orderedElements.append(element)
            seenIDs.insert(id)
        }

        for element in elements where !seenIDs.contains(element.id) {
            orderedElements.append(element)
            seenIDs.insert(element.id)
        }

        return orderedElements
    }
}
