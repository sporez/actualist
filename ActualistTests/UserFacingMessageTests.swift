import Foundation
import GRDB
import Testing
@testable import Actualist

struct UserFacingMessageTests {
    private enum UntypedError: Error { case failed }

    private struct Keyed: Decodable { let secretFieldName: String }

    @Test func developerWriteReasonsStayOffScreen() {
        let message = LocalFirstError.invalidLocalWrite("invalid zero_budgets row").userFacingMessage
        #expect(message == "Actualist could not save this change. Try again.")
        #expect(LocalFirstError.schemaUnavailable("missing payees table").userFacingMessage?
            .contains("payees table") == false)
        #expect(LocalFirstError.referencedRowUnavailable("missing account").userFacingMessage?
            .contains("missing account") == false)
    }

    @Test func refusedChangeShowsItsSentence() {
        let sentence = "A category with the name Food already exists."
        #expect(LocalFirstError.refusedChange(sentence).userFacingMessage == sentence)
    }

    @Test func shortcutsCarryTheRefusalSentence() {
        let sentence = "There is nothing to undo."
        let mapped = ShortcutsError.mapping(LocalFirstError.refusedChange(sentence))
        #expect(mapped == .refused(sentence))
        #expect(mapped.errorDescription == sentence)
        #expect(ShortcutsError.mapping(LocalFirstError.invalidLocalWrite("missing category")) == .writeFailed)
    }

    @Test func sqliteAndStatusCodeErrorsGetTheGenericSentence() {
        let sqlite = DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "UNIQUE constraint failed: payees.name")
        #expect(sqlite.userFacingMessage == UserFacingErrorText.genericFailure)
        let status = NSError(domain: NSOSStatusErrorDomain, code: -25308)
        #expect(status.userFacingMessage == UserFacingErrorText.genericFailure)
        #expect(UntypedError.failed.userFacingMessage == UserFacingErrorText.genericFailure)
    }

    @Test func decodingErrorsDoNotNameTheirCodingPath() throws {
        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(Keyed.self, from: Data("{}".utf8))
        }
        let message = try #require(error.userFacingMessage)
        #expect(!message.contains("secretFieldName"))
    }

    @Test func foundationNetworkErrorsKeepTheirSystemText() {
        let offline = URLError(.notConnectedToInternet)
        #expect(offline.userFacingMessage == offline.localizedDescription)
    }

    @Test func cancellationHasNoMessage() {
        #expect(CancellationError().userFacingMessage == nil)
    }
}
