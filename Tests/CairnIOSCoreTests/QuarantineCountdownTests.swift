import Foundation
import Testing
@testable import CairnIOSCore

/// Guards the Status quarantine banner's "next in N days" countdown. It
/// must round the SAME way as PendingReviewScreen's per-item "Trashes in
/// N days" card (ceiling of the remaining seconds) so the banner and the
/// drill-down agree. A prior calendar-day truncation disagreed by up to a
/// day. Offsets are kept off integer-day boundaries so the few
/// microseconds between constructing the date and `relativeDay` reading
/// `timeIntervalSinceNow` can't flip a boundary and flake the test.
@Suite("Status quarantine banner countdown")
struct QuarantineCountdownTests {
    private func inDays(_ days: Double) -> Date {
        Date().addingTimeInterval(days * 86_400)
    }

    @Test("rounds up: 4.3 days out → \"5 days\"")
    func ceilFractional() {
        #expect(StatusScreen.relativeDay(inDays(4.3)) == "5 days")
    }

    @Test("under a day still reads \"1 day\", not \"<1d\"")
    func underOneDay() {
        #expect(StatusScreen.relativeDay(inDays(0.5)) == "1 day")
    }

    @Test("just over a day rounds up to \"2 days\"")
    func justOverOneDay() {
        #expect(StatusScreen.relativeDay(inDays(1.1)) == "2 days")
    }

    @Test("singular vs plural: exactly-in-window fractional day is singular")
    func singularPlural() {
        #expect(StatusScreen.relativeDay(inDays(0.9)) == "1 day")
        #expect(StatusScreen.relativeDay(inDays(13.2)) == "14 days")
    }
}
