import Foundation
import Testing
@testable import Actualist

struct StringSearchMatchingTests {
    @Test func matchingIgnoresCaseAndDiacritics() {
        #expect("Café Rouge".matchesSearch("cafe"))
        #expect("Café Rouge".matchesSearch("ROUGE"))
        #expect("Cafe".matchesSearch("café"))
        #expect(!"Café Rouge".matchesSearch("bleu"))
    }

    @Test func weekdayNamesAreSharedAndAbbreviateToThreeLetters() {
        let names: [(ActualScheduleWeekday, String)] = [
            (.sunday, "Sunday"), (.monday, "Monday"), (.tuesday, "Tuesday"), (.wednesday, "Wednesday"),
            (.thursday, "Thursday"), (.friday, "Friday"), (.saturday, "Saturday")
        ]
        for (weekday, name) in names {
            #expect(weekday.fullName == name)
        }
    }
}
