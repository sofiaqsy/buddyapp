import XCTest
@testable import BuddyApp

/// Primeras pruebas automáticas (paso 1, 20 Nov 2026): resumen del horario.
final class HoursSummaryTests: XCTestCase {
    private func day(_ d: Int, _ open: Bool = true, _ from: Int = 8 * 60, _ to: Int = 18 * 60) -> DayHours {
        DayHours(day: d, open: open, from: from, to: to)
    }

    func test_time_morningAndAfternoon_formatsTwelveHour() {
        XCTAssertEqual(HoursSummary.time(8 * 60), "8:00 a. m.")
        XCTAssertEqual(HoursSummary.time(18 * 60 + 30), "6:30 p. m.")
        XCTAssertEqual(HoursSummary.time(12 * 60), "12:00 p. m.")
        XCTAssertEqual(HoursSummary.time(0), "12:00 a. m.")
    }

    func test_text_allClosed_saysClosedEveryDay() {
        XCTAssertEqual(HoursSummary.text((0..<7).map { day($0, false) }), "Cerrado todos los días")
    }

    func test_text_sameHoursAllWeek_saysEveryDay() {
        XCTAssertEqual(HoursSummary.text((0..<7).map { day($0) }), "Todos los días · 8:00 a. m. – 6:00 p. m.")
    }

    func test_text_defaults_groupsMondayToSaturday() {
        XCTAssertEqual(HoursSummary.text(DayHours.defaults()), "Lun–Sáb · 8:00 a. m. – 6:00 p. m.")
    }

    func test_text_saturdayShorter_makesTwoGroups() {
        var days = (0..<5).map { day($0) }
        days.append(day(5, true, 9 * 60, 13 * 60))
        days.append(day(6, false))
        XCTAssertEqual(HoursSummary.text(days),
                       "Lun–Vie · 8:00 a. m. – 6:00 p. m. · Sáb · 9:00 a. m. – 1:00 p. m.")
    }

    func test_text_unsortedInput_sameResult() {
        XCTAssertEqual(HoursSummary.text(DayHours.defaults().reversed()), "Lun–Sáb · 8:00 a. m. – 6:00 p. m.")
    }

    func test_text_gapInWeek_doesNotJoinAcrossClosedDay() {
        let days = [day(0), day(1), day(2, false), day(3), day(4), day(5, false), day(6, false)]
        XCTAssertEqual(HoursSummary.text(days),
                       "Lun–Mar · 8:00 a. m. – 6:00 p. m. · Jue–Vie · 8:00 a. m. – 6:00 p. m.")
    }
}
