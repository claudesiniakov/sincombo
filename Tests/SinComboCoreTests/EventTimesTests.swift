import XCTest
@testable import SinComboCore

final class EventTimesTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testAllDayEndsAtNextMidnight() throws {
        let bounds = try XCTUnwrap(EventTimes.bounds(
            start: date(2026, 11, 11, 15, 30), end: date(2026, 11, 11, 16, 30),
            allDay: true, calendar: calendar
        ))
        XCTAssertEqual(bounds.start, date(2026, 11, 11))
        XCTAssertEqual(bounds.end, date(2026, 11, 12))
    }

    func testAllDayIgnoresTimeOfDay() throws {
        let bounds = try XCTUnwrap(EventTimes.bounds(
            start: date(2026, 11, 11, 23, 59), end: date(2026, 11, 11, 23, 59),
            allDay: true, calendar: calendar
        ))
        XCTAssertEqual(bounds.start, date(2026, 11, 11))
        XCTAssertEqual(bounds.end, date(2026, 11, 12))
    }

    func testTimedEventKeepsBounds() throws {
        let start = date(2026, 11, 11, 9), end = date(2026, 11, 11, 10)
        let bounds = try XCTUnwrap(EventTimes.bounds(start: start, end: end, allDay: false, calendar: calendar))
        XCTAssertEqual(bounds.start, start)
        XCTAssertEqual(bounds.end, end)
    }

    func testTimedEventWithEmptyRangeIsRejected() {
        let start = date(2026, 11, 11, 9)
        XCTAssertNil(EventTimes.bounds(start: start, end: start, allDay: false, calendar: calendar))
        XCTAssertNil(EventTimes.bounds(start: start, end: start.addingTimeInterval(-60), allDay: false, calendar: calendar))
    }
}
