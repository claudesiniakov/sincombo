import XCTest
@testable import SinComboCore

final class PanelLayoutTests: XCTestCase {
    func testDefaultsAndLastModuleStaysOn() {
        var layout = PanelLayout()
        XCTAssertEqual(layout.order, ModuleID.allCases)
        XCTAssertEqual(layout.visible, ModuleID.allCases)
        for id in ModuleID.allCases { layout.setEnabled(id, false) }
        XCTAssertEqual(layout.visible.count, 1)
        XCTAssertFalse(layout.canDisable(layout.visible[0]))
        layout.setEnabled(.wifi, true)
        XCTAssertTrue(layout.isEnabled(.wifi))
    }

    func testMove() {
        var layout = PanelLayout()
        layout.move(.subs, by: -1)
        XCTAssertEqual(layout.order.suffix(2), [.subs, .battery])
        layout.move(.calendar, by: -1)
        XCTAssertEqual(layout.order.first, .calendar)
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(Array(layout.order.prefix(3)), [.sound, .wifi, .calendar])
        layout.move(fromOffsets: IndexSet(integer: 6), toOffset: 0)
        XCTAssertEqual(layout.order.first, .battery)
        XCTAssertEqual(Set(layout.order).count, ModuleID.allCases.count)
    }

    func testDecodingAddsNewModulesAndSkipsUnknown() throws {
        let json = #"{"order":["wifi","future","calendar","wifi"],"disabled":["calendar","future"]}"#
        let layout = try JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8))
        XCTAssertEqual(Array(layout.order.prefix(2)), [.wifi, .calendar])
        XCTAssertEqual(layout.order.count, ModuleID.allCases.count)
        XCTAssertFalse(layout.isEnabled(.calendar))
        XCTAssertTrue(layout.isEnabled(.subs))
        let again = try JSONDecoder().decode(PanelLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(again, layout)
    }
}

final class CalendarGridTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        c.locale = Locale(identifier: "ru_RU")
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testNovember2026() {
        let weeks = CalendarGrid.weeks(forMonthContaining: date(2026, 11, 11), calendar: calendar)
        // 1 ноября 2026 — воскресенье: первая неделя начинается с понедельника 26 октября.
        XCTAssertEqual(weeks.count, 6)
        XCTAssertEqual(weeks[0].days.map(\.day), [26, 27, 28, 29, 30, 31, 1])
        XCTAssertEqual(weeks[0].days.map(\.inMonth), [false, false, false, false, false, false, true])
        XCTAssertEqual(weeks[0].days.map(\.isWeekend), [false, false, false, false, false, true, true])
        XCTAssertEqual(weeks[0].number, 44)
        XCTAssertEqual(weeks[5].days.first?.day, 30)
        XCTAssertTrue(weeks.allSatisfy { $0.days.count == 7 })
    }

    func testFebruaryFitsFourWeeks() {
        // Февраль 2027 начинается в понедельник и занимает ровно 4 недели.
        let weeks = CalendarGrid.weeks(forMonthContaining: date(2027, 2, 10), calendar: calendar)
        XCTAssertEqual(weeks.count, 4)
        XCTAssertTrue(weeks.flatMap(\.days).allSatisfy(\.inMonth))
    }

    func testWeekdayHeaders() {
        let headers = CalendarGrid.weekdayHeaders(calendar: calendar)
        XCTAssertEqual(headers.count, 7)
        XCTAssertEqual(headers.map(\.isWeekend), [false, false, false, false, false, true, true])
    }

    func testMeetingLinks() {
        XCTAssertEqual(
            MeetingLinks.find(in: [nil, "Офис", "Подключение: https://us02web.zoom.us/j/123456?pwd=abc."])?.absoluteString,
            "https://us02web.zoom.us/j/123456?pwd=abc"
        )
        XCTAssertEqual(
            MeetingLinks.find(in: ["https://meet.google.com/abc-defg-hij"])?.host, "meet.google.com"
        )
        XCTAssertNil(MeetingLinks.find(in: ["https://example.com/page", nil]))
    }
}

final class DeviceLogicTests: XCTestCase {
    func testWiFiBarsAndArrange() {
        XCTAssertEqual(WiFiLogic.bars(rssi: -40), 4)
        XCTAssertEqual(WiFiLogic.bars(rssi: -60), 3)
        XCTAssertEqual(WiFiLogic.bars(rssi: -75), 2)
        XCTAssertEqual(WiFiLogic.bars(rssi: -90), 1)
        let list = WiFiNetwork.arrange([
            WiFiNetwork(ssid: "B", rssi: -70, secured: true, known: true),
            WiFiNetwork(ssid: "A", rssi: -50, secured: true, known: false),
            WiFiNetwork(ssid: "B", rssi: -45, secured: true, known: true),
            WiFiNetwork(ssid: "", rssi: -30, secured: false, known: false),
            WiFiNetwork(ssid: "Home", rssi: -80, secured: true, known: true),
        ], current: "Home")
        XCTAssertEqual(list.map(\.ssid), ["Home", "B", "A"])
        XCTAssertEqual(list[1].rssi, -45)
    }

    func testBluetoothBattery() {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods Pro":{"device_address":"AA-BB-CC-11-22-33","device_batteryLevelLeft":"82%","device_batteryLevelRight":"80%","device_batteryLevelCase":"64%"}},
          {"Magic Mouse":{"device_address":"aa:bb:cc:44:55:66","device_batteryLevelMain":"47%"}}],
          "device_not_connected":[{"Keychron":{"device_address":"11:22:33:44:55:66"}}]}]}
        """
        let levels = BluetoothBattery.parse(Data(json.utf8))
        XCTAssertEqual(levels["AA:BB:CC:11:22:33"], "Л 82 % · П 80 % · футляр 64 %")
        XCTAssertEqual(levels["AA:BB:CC:44:55:66"], "47 %")
        XCTAssertNil(levels["11:22:33:44:55:66"])
        XCTAssertTrue(BluetoothBattery.parse(Data("мусор".utf8)).isEmpty)
    }

    func testBatteryFormat() {
        XCTAssertEqual(BatteryFormat.time(minutes: 400), "6 ч 40 мин")
        XCTAssertEqual(BatteryFormat.time(minutes: 48), "48 мин")
        XCTAssertEqual(BatteryFormat.time(minutes: -1), "Расчёт…")
        XCTAssertEqual(BatteryFormat.health(rawMax: 4200, design: 4380), 96)
        XCTAssertNil(BatteryFormat.health(rawMax: 0, design: 4380))
    }
}

final class SubscriptionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testPeriodBeforeRenewal() throws {
        let p = try XCTUnwrap(PeriodProgress.compute(renewal: date(2026, 11, 24), period: .month, now: date(2026, 11, 11), calendar: calendar))
        XCTAssertEqual(p.daysTotal, 31)
        XCTAssertEqual(p.daysPassed, 18)
        XCTAssertEqual(p.daysLeft, 13)
        XCTAssertEqual(p.fraction, 18.0 / 31.0, accuracy: 0.0001)
    }

    func testRenewalInPastRollsForward() throws {
        let p = try XCTUnwrap(PeriodProgress.compute(renewal: date(2026, 1, 31), period: .month, now: date(2026, 3, 15), calendar: calendar))
        XCTAssertEqual(calendar.component(.month, from: p.end), 3)
        XCTAssertEqual(calendar.component(.day, from: p.end), 31)
        XCTAssertEqual(calendar.component(.day, from: p.start), 28)
        let onDay = try XCTUnwrap(PeriodProgress.compute(renewal: date(2026, 11, 11), period: .year, now: date(2026, 11, 11), calendar: calendar))
        XCTAssertEqual(onDay.daysPassed, 0)
        XCTAssertEqual(onDay.daysTotal, 365)
    }

    func testAnthropicCostInCents() throws {
        let json = #"{"data":[{"starting_at":"2026-11-01T00:00:00Z","results":[{"amount":"123.45","currency":"USD"},{"amount":"76.55","currency":"USD"}]},{"results":[]}],"has_more":true,"next_page":"page_x"}"#
        let parsed = try XCTUnwrap(UsageParsers.anthropicCostUSD(Data(json.utf8)))
        XCTAssertEqual(parsed.usd, 2.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.nextPage, "page_x")
        XCTAssertNil(UsageParsers.anthropicCostUSD(Data("{}".utf8)))
    }

    func testOpenAICost() throws {
        let json = #"{"object":"page","data":[{"results":[{"amount":{"value":1.25,"currency":"usd"}}]},{"results":[{"amount":{"value":0.75,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#
        let parsed = try XCTUnwrap(UsageParsers.openAICostUSD(Data(json.utf8)))
        XCTAssertEqual(parsed.usd, 2.0, accuracy: 0.0001)
        XCTAssertNil(parsed.nextPage)
    }

    func testClaudeLimitsAndToken() throws {
        let now = date(2026, 11, 11, 10)
        let json = #"{"five_hour":{"utilization":42.0,"resets_at":"2026-11-11T12:10:00Z"},"seven_day":{"utilization":74,"resets_at":"2026-11-16T09:00:00+00:00"},"seven_day_opus":null}"#
        let limits = try XCTUnwrap(UsageParsers.claudeLimits(Data(json.utf8), now: now))
        XCTAssertEqual(limits.map(\.title), ["Сессия, 5 часов", "Неделя"])
        XCTAssertEqual(limits[0].fraction ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(limits[0].caption, "сброс через 2 ч 10 мин")
        XCTAssertEqual(limits[1].fraction ?? 0, 0.74, accuracy: 0.0001)
        XCTAssertNil(UsageParsers.claudeLimits(Data("{}".utf8), now: now))

        let ms = (now.timeIntervalSince1970 + 3600) * 1000
        let creds = "{\"claudeAiOauth\":{\"accessToken\":\"tok\",\"expiresAt\":\(ms)}}"
        let token = try XCTUnwrap(UsageParsers.claudeCodeToken(Data(creds.utf8), now: now))
        XCTAssertEqual(token.token, "tok")
        XCTAssertFalse(token.expired)
        XCTAssertNil(UsageParsers.claudeCodeToken(Data("{}".utf8), now: now))
        XCTAssertEqual(MoneyFormat.usd(12.4), "12,40 $")
    }
}
