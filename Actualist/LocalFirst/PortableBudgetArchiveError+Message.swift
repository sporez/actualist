import Foundation

/// Plain-language import failures. Each message names what was wrong with the
/// file, so a report from a tester identifies the failed check.
extension PortableBudgetArchiveError: LocalizedError {
    var errorDescription: String? {
        switch reason {
        case .unsafePath, .symbolicLink, .splitDirectories, .ambiguous:
            String(localized: "This ZIP isn't a budget export. Its files aren't laid out the way Actual exports them.")
        case .resourceLimit:
            String(localized: "This ZIP is too large to import.")
        case .insufficientStorage:
            String(localized: "There isn't enough free space on this device to import the budget.")
        case .truncated, .checksumMismatch:
            String(localized: "This ZIP is incomplete or damaged. Export the budget again and retry.")
        case .missingDatabase:
            String(localized: "This ZIP has no budget database in it.")
        case .missingMetadata:
            String(localized: "This ZIP is missing its budget details file (metadata.json).")
        case .malformedMetadata, .oversizedMetadata:
            String(localized: "This ZIP's budget details file (metadata.json) can't be read.")
        case .integrity:
            String(localized: "The budget database in this ZIP failed its safety check.")
        case .unsupportedSchema:
            String(localized: "The budget in this ZIP uses a format this version of Actualist doesn't support.")
        }
    }
}
