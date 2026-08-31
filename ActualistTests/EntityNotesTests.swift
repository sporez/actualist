import Foundation
import GRDB
import Testing
@testable import Actualist

struct ActualNoteValueTests {
    @Test func targetIDsMatchActualConventionsAndRejectEmptyIdentity() throws {
        #expect(try #require(ActualNoteTarget.category(id: "cat-1", title: "Groceries")).noteID == "cat-1")
        #expect(try #require(ActualNoteTarget.categoryGroup(id: "group-1", title: "Everyday")).noteID == "group-1")
        #expect(try #require(ActualNoteTarget.account(id: "acct-1", title: "Checking")).noteID == "account-acct-1")
        #expect(try #require(ActualNoteTarget.budgetMonth(month: "2026-07", title: "Jul 2026")).noteID == "budget-2026-07")
        #expect(ActualNoteTarget.category(id: "  ", title: "Missing") == nil)
        #expect(ActualNoteTarget.account(id: "", title: "Missing") == nil)
    }

    @Test func reservedDirectivesAreHiddenAndPreservedInOriginalOrder() {
        let body = ActualNoteBody(storedNote: "Visible one\n  #Template 100\nVisible two\n#goal 500\n#CLEANUP")

        #expect(body.userBody == "Visible one\nVisible two")
        #expect(body.displayText == "Visible one\nVisible two")
        #expect(body.hasUserNote)
        #expect(body.reservedLines == ["  #Template 100", "#goal 500", "#CLEANUP"])
        #expect(
            body.persistedNote(userBody: "Updated")
                == "Updated\n  #Template 100\n#goal 500\n#CLEANUP"
        )
    }

    @Test func markdownPresentationRendersOnlyTheUserFacingBody() throws {
        let body = ActualNoteBody(
            storedNote: "Remember **coupons** and [store policy](https://example.com).\n#template 250"
        )
        let presentation = try #require(ActualNotePresentation(userBody: body.displayText))

        #expect(
            String(presentation.attributedText.characters)
                == "Remember coupons and store policy."
        )
        #expect(!String(presentation.attributedText.characters).contains("template"))
        #expect(
            presentation.attributedText.runs.contains {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        )
        #expect(
            presentation.attributedText.runs.contains {
                $0.link == URL(string: "https://example.com")
            }
        )
        #expect(ActualNotePresentation(userBody: " \n\t ") == nil)
    }

    @Test func proseMentionsRemainVisibleAndWhitespaceOnlyClearsUserBody() {
        let prose = ActualNoteBody(storedNote: "Use the template from last year")
        #expect(prose.userBody == "Use the template from last year")
        #expect(prose.reservedLines.isEmpty)

        #expect(prose.persistedNote(userBody: " \n\t ") == nil)

        let reserved = ActualNoteBody(storedNote: "#template 250\n#goal 500")
        #expect(!reserved.hasUserNote)
        #expect(reserved.persistedNote(userBody: "  ") == "#template 250\n#goal 500")
    }
}

@MainActor
struct EntityNotesViewModelTests {
    @Test func privacyModeNeverLoadsOrSavesNoteText() async throws {
        let target = try #require(ActualNoteTarget.category(id: "cat-1", title: "Groceries"))
        let repository = FakeEntityNotesRepository(note: ActualNoteBody(storedNote: "Secret"))
        let viewModel = EntityNotesViewModel(
            target: target,
            budgetID: "budget-1",
            isPrivacyModeEnabled: true
        )

        await viewModel.load(repository: repository)
        let saved = await viewModel.save(repository: repository)

        #expect(viewModel.phase == .privacy)
        #expect(viewModel.text.isEmpty)
        #expect(!saved)
        #expect(repository.loadCount == 0)
        #expect(repository.savedBodies.isEmpty)
    }

    @Test func categoryDetailsLoadsTheTrimmedUserFacingBody() async {
        let repository = FakeEntityNotesRepository(
            note: ActualNoteBody(storedNote: "  Remember coupons  \n#template 250")
        )
        let viewModel = CategoryMonthDetailsViewModel(details: Self.categoryDetails)

        await viewModel.loadCategoryNote(
            budgetID: "budget-1",
            isPrivacyModeEnabled: false,
            repository: repository
        )

        #expect(
            viewModel.categoryNotePresentation.map { String($0.attributedText.characters) }
                == "Remember coupons"
        )
        #expect(repository.loadCount == 1)
    }

    @Test func categoryDetailsPrivacyModeInvalidatesAStaleNoteLoad() async {
        let repository = FakeEntityNotesRepository(note: ActualNoteBody(storedNote: "Secret"))
        repository.suspendLoad = true
        let viewModel = CategoryMonthDetailsViewModel(details: Self.categoryDetails)

        let load = Task {
            await viewModel.loadCategoryNote(
                budgetID: "budget-1",
                isPrivacyModeEnabled: false,
                repository: repository
            )
        }
        while repository.resumeLoad == nil {
            await Task.yield()
        }
        await viewModel.loadCategoryNote(
            budgetID: "budget-1",
            isPrivacyModeEnabled: true,
            repository: repository
        )
        repository.finishLoad()
        await load.value

        #expect(viewModel.categoryNotePresentation == nil)
        #expect(repository.loadCount == 1)
    }

    @Test func cancelInvalidatesAStaleLoadResult() async throws {
        let target = try #require(ActualNoteTarget.category(id: "cat-1", title: "Groceries"))
        let repository = FakeEntityNotesRepository(note: ActualNoteBody(storedNote: "Remote"))
        repository.suspendLoad = true
        let viewModel = EntityNotesViewModel(
            target: target,
            budgetID: "budget-1",
            isPrivacyModeEnabled: false
        )

        let task = Task { await viewModel.load(repository: repository) }
        while repository.resumeLoad == nil {
            await Task.yield()
        }
        viewModel.cancel()
        repository.finishLoad()
        await task.value

        #expect(viewModel.phase == .idle)
        #expect(viewModel.text.isEmpty)
    }

    private static let categoryDetails = CategoryMonthDetails(
        category: BudgetMonthCategory(
            id: "groceries",
            name: "Groceries",
            isIncome: false,
            hidden: false,
            groupID: "essentials",
            budgeted: 50_000,
            spent: -12_000,
            balance: 38_000,
            carryover: false,
            hasUserNote: true
        ),
        month: "2026-08"
    )
}

@MainActor
private final class FakeEntityNotesRepository: EntityNotesRepositoryProtocol {
    let note: ActualNoteBody
    var loadCount = 0
    var savedBodies: [String] = []
    var suspendLoad = false
    var resumeLoad: CheckedContinuation<Void, Never>?

    init(note: ActualNoteBody) {
        self.note = note
    }

    func entityNote(target: ActualNoteTarget, budgetID: String) async throws -> ActualNoteBody {
        loadCount += 1
        if suspendLoad {
            await withCheckedContinuation { continuation in
                resumeLoad = continuation
            }
        }
        return note
    }

    func setEntityNoteAndRefresh(
        target: ActualNoteTarget,
        userBody: String,
        budgetID: String
    ) async throws {
        savedBodies.append(userBody)
    }

    func finishLoad() {
        resumeLoad?.resume()
        resumeLoad = nil
    }
}

extension LocalFirstActualStoreTests {
    @Test func entityNoteFlagsAndWritesUseTheNotesDataset() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', 'Remember coupons\n#template 250');
            INSERT INTO notes VALUES ('utilities', '#goal 500');
            INSERT INTO notes VALUES ('group', 'Core monthly costs');
            INSERT INTO notes VALUES ('account-checking', 'Primary spending account');
            INSERT INTO notes VALUES ('budget-2026-07', 'July focus');
            """)
        let store = bundle.store
        let categoryTarget = try #require(
            ActualNoteTarget.category(id: "groceries", title: "Groceries")
        )

        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let group = try #require(loaded.month.categoryGroups.first { $0.id == "group" })
        let groceries = try #require(group.categories.first { $0.id == "groceries" })
        let utilities = try #require(group.categories.first { $0.id == "utilities" })
        #expect(loaded.month.hasUserNote)
        #expect(group.hasUserNote)
        #expect(groceries.hasUserNote)
        #expect(!utilities.hasUserNote)
        #expect(store.accountDisplays(budgetID: "group-1").first { $0.id == "checking" }?.hasUserNote == true)

        let body = try await store.entityNote(target: categoryTarget, budgetID: "group-1")
        #expect(body.userBody == "Remember coupons")
        #expect(body.reservedLines == ["#template 250"])

        try await store.setEntityNoteAndRefresh(
            target: categoryTarget,
            userBody: "Updated note",
            budgetID: "group-1"
        )

        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let queue = try DatabaseQueue(path: databaseURL.path)
        let storedNote = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT note FROM notes WHERE id = 'groceries'")
        }
        #expect(storedNote == "Updated note\n#template 250")

        let noteMessages = try storedCRDTMessages(at: databaseURL).filter { $0.dataset == "notes" }
        #expect(noteMessages.count == 1)
        #expect(noteMessages[0].row == "groceries")
        #expect(noteMessages[0].column == "note")
        #expect(noteMessages[0].serializedValue == "S:Updated note\n#template 250")

        try await store.setEntityNoteAndRefresh(
            target: categoryTarget,
            userBody: "",
            budgetID: "group-1"
        )
        let refreshedCategory = store.cachedBudgetMonth(budgetID: "group-1")?.month
            .categoryGroups.flatMap(\.categories)
            .first { $0.id == "groceries" }
        #expect(refreshedCategory?.hasUserNote == false)
        let preservedDirective = try await store.entityNote(
            target: categoryTarget,
            budgetID: "group-1"
        )
        #expect(preservedDirective.persistedNote(userBody: "") == "#template 250")
    }

    @Test func inboundNotesMessagesApplyThroughTheGenericSyncPath() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            """)
        let database = try #require(bundle.store.database)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-25T12:00:00.000Z-0000-remote",
            dataset: "notes",
            row: "groceries",
            column: "note",
            serializedValue: "S:Added in Actual web"
        )

        #expect(try await database.applyRemoteSyncMessages([message]) == 1)
        let target = try #require(ActualNoteTarget.category(id: "groceries", title: "Groceries"))
        let note = try await bundle.store.entityNote(target: target, budgetID: "group-1")
        #expect(note.userBody == "Added in Actual web")
    }

    @Test func clearingUserTextWritesNullUnlessReservedLinesRemain() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('groceries', 'Visible');
            INSERT INTO notes VALUES ('utilities', 'Visible\n#cleanup');
            """)
        let store = bundle.store
        let groceries = try #require(ActualNoteTarget.category(id: "groceries", title: "Groceries"))
        let utilities = try #require(ActualNoteTarget.category(id: "utilities", title: "Utilities"))

        try await store.setEntityNoteAndRefresh(target: groceries, userBody: " \n ", budgetID: "group-1")
        try await store.setEntityNoteAndRefresh(target: utilities, userBody: "", budgetID: "group-1")

        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let queue = try DatabaseQueue(path: databaseURL.path)
        let values = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, note FROM notes ORDER BY id").reduce(into: [String: String?]()) {
                $0[$1["id"]] = .some($1["note"] as String?)
            }
        }
        #expect(values["groceries"] == .some(nil))
        #expect(values["utilities"] == .some("#cleanup"))
    }

    @Test func missingNotesTableReadsEmptyAndFailsClosedOnWrite() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let target = try #require(ActualNoteTarget.account(id: "checking", title: "Checking"))

        let body = try await bundle.store.entityNote(target: target, budgetID: "group-1")
        #expect(!body.hasUserNote)
        #expect(body.reservedLines.isEmpty)
        await #expect(throws: LocalFirstError.self) {
            try await bundle.store.setEntityNoteAndRefresh(
                target: target,
                userBody: "Should fail",
                budgetID: "group-1"
            )
        }
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let tables = try sqliteTables(at: databaseURL)
        #expect(!tables.contains("notes"))
    }
}
