import Foundation

/// The money-input contract Actual's own amount-field code produced. See
/// `scripts/money-input-parity/README.md` for what each mode ran.
struct MoneyInputOracleFixture: Decodable {
    struct Outcome: Decodable, Equatable {
        let kind: String
        let value: Int?
        let repr: String?
    }

    struct Input: Decodable {
        let text: String?
        let minorUnits: Int?
        let numberFormat: String
        let currencyCode: String
        let decimalPlaces: Int
        let hideFraction: Bool?
    }

    enum Expected: Equatable {
        case fromEdit(Outcome)
        case forEdit(text: String, parsedBack: Outcome)
        case autoDecimals(editText: String, amount: Outcome, displayThrew: Bool)
    }

    struct Case: Decodable {
        let id: String
        let mode: String
        let input: Input
        let expected: Expected

        private enum CodingKeys: String, CodingKey { case id, mode, input, expected }
        private struct ForEdit: Decodable { let text: String; let parsedBack: Outcome }
        private struct AutoDecimals: Decodable { let editText: String; let amount: Outcome; let displayThrew: Bool }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            mode = try container.decode(String.self, forKey: .mode)
            input = try container.decode(Input.self, forKey: .input)
            switch mode {
            case "fromEdit":
                expected = .fromEdit(try container.decode(Outcome.self, forKey: .expected))
            case "forEdit":
                let value = try container.decode(ForEdit.self, forKey: .expected)
                expected = .forEdit(text: value.text, parsedBack: value.parsedBack)
            case "autoDecimals":
                let value = try container.decode(AutoDecimals.self, forKey: .expected)
                expected = .autoDecimals(editText: value.editText, amount: value.amount, displayThrew: value.displayThrew)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: container, debugDescription: "unknown mode \(mode)"
                )
            }
        }
    }

    struct Currency: Decodable {
        let code: String
        let decimalPlaces: Int
    }

    /// Actual's currency list (`shared/currencies.ts`), as the harness read it.
    let currencies: [Currency]
    let cases: [Case]

    static func load() throws -> Self {
        let url = try ParityOraclePin.fixtureURL("MoneyInput").appending(path: "money-input-contract.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
