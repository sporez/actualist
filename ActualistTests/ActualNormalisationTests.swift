import Testing
@testable import Actualist

struct ActualNormalisationTests {
    @Test(arguments: [
        ("Éclair", "eclair"),
        ("Straße Café", "strasse cafe"),
        ("ŁÓDŹ", "lodz"),
        ("Œuvre", "oeuvre"),
        ("Grocer ", "grocer "),
        ("ØRE", "ore"),
        ("", ""),
    ])
    func matchesActualNormalisation(input: String, expected: String) {
        #expect(input.actualNormalised == expected)
    }
}
