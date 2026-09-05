import Foundation

enum MonthDisplayPreference: Codable, Equatable, Hashable, CaseIterable, Identifiable {
    case automatic
    case fixed(Int)

    static var allCases: [Self] { [.automatic, .fixed(1), .fixed(2), .fixed(3), .fixed(4), .fixed(5)] }
    var id: String { rawValue }
    var rawValue: String {
        switch self { case .automatic: "auto"; case .fixed(let count): "\(count)" }
    }
    var title: String { self == .automatic ? "Auto" : rawValue }
    var resolvedCount: Int { if case .fixed(let count) = self { return min(max(count, 1), 5) }; return 5 }

    init(rawValue: String) {
        if rawValue == "auto" { self = .automatic }
        else if let count = Int(rawValue), (1...5).contains(count) { self = .fixed(count) }
        else { self = .automatic }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = try? container.decode(String.self) else {
            self = .automatic
            return
        }
        self.init(rawValue: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
