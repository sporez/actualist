import Testing
@testable import Actualist

struct EntityNameTests {
    @Test func trimsSurroundingWhitespace() throws {
        #expect(try EntityName.validatedName("  Rent \n", label: "category") == "Rent")
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func blankNameThrowsWithItsLabel(name: String) {
        #expect {
            try EntityName.validatedName(name, label: "account group")
        } throws: { error in
            guard case LocalFirstError.invalidLocalWrite(let message) = error else { return false }
            return message == "account group name cannot be empty"
        }
    }
}
