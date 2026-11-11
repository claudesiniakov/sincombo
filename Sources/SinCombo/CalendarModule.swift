import SwiftUI
import EventKit
import SinComboCore

struct DayEvent: Identifiable, Equatable {
    let id: String
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    let location: String?
    let link: URL?
}

struct CalendarInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
    let writable: Bool
}

@MainActor
@Observable
final class CalendarModel {
    enum Access { case unknown, granted, denied }

    var month = Date()
    var selected = Date()
    private(set) var today = Date()
    private(set) var access: Access = .unknown
    private(set) var events: [Date: [DayEvent]] = [:]
    private(set) var calendars: [CalendarInfo] = []
    private(set) var saveError: String?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var requested = false

    var calendar: Calendar { Calendar.autoupdatingCurrent }

    var weeks: [GridWeek] { CalendarGrid.weeks(forMonthContaining: month, calendar: calendar) }

    func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in AppState.shared.calendar.reload() }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.calendar.dayChanged() }
        }
        readAccess()
    }

    private func readAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    /// Доступ запрашивается только когда события включены и панель открыта.
    func activate(wantEvents: Bool) {
        start()
        dayChanged()
        guard wantEvents else { return }
        if access == .unknown, !requested {
            requested = true
            Task {
                _ = try? await store.requestFullAccessToEvents()
                self.readAccess()
                self.reload()
            }
        } else {
            reload()
        }
    }

    func dayChanged() {
        let now = Date()
        if !calendar.isDate(now, inSameDayAs: today) {
            // После полуночи выбранный «сегодняшний» день едет вместе с датой.
            if calendar.isDate(selected, inSameDayAs: today) {
                selected = now
                month = now
            }
        }
        today = now
    }

    func reload() {
        readAccess()
        guard access == .granted else {
            if !events.isEmpty { events = [:] }
            return
        }
        let hidden = Prefs.shared.hiddenCalendars
        let all = store.calendars(for: .event)
        let infos = all.map {
            CalendarInfo(
                id: $0.calendarIdentifier, title: $0.title,
                color: Color(cgColor: $0.cgColor), writable: $0.allowsContentModifications
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if calendars != infos { calendars = infos }

        let shown = all.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else {
            events = [:]
            return
        }
        // Диапазон: видимая сетка месяца плюс сегодняшний день (для текста в строке меню).
        let grid = weeks
        guard var from = grid.first?.days.first?.date, let last = grid.last?.days.last?.date,
              var to = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        let dayStart = calendar.startOfDay(for: today)
        if dayStart < from { from = dayStart }
        if let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart), dayEnd > to { to = dayEnd }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: shown)
        var result: [Date: [DayEvent]] = [:]
        for event in store.events(matching: predicate) {
            guard let start = event.startDate, let end = event.endDate else { continue }
            let item = DayEvent(
                id: (event.calendarItemIdentifier) + "@\(start.timeIntervalSince1970)",
                eventID: event.calendarItemIdentifier,
                title: event.title?.isEmpty == false ? event.title! : "Без названия",
                start: start,
                end: end,
                allDay: event.isAllDay,
                color: Color(cgColor: event.calendar.cgColor),
                location: event.location?.isEmpty == false ? event.location : nil,
                link: MeetingLinks.find(in: [event.url?.absoluteString, event.location, event.notes])
            )
            // Многодневное событие показывается в каждом своём дне.
            var day = calendar.startOfDay(for: max(start, from))
            // Событие «на весь день» кончается в полночь следующего дня — её не считаем.
            let lastMoment = end > start ? end.addingTimeInterval(-1) : end
            var guardCount = 0
            while day <= lastMoment, day < to, guardCount < 62 {
                result[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                guardCount += 1
            }
        }
        for key in result.keys {
            result[key]?.sort { a, b in
                if a.allDay != b.allDay { return a.allDay }
                if a.start != b.start { return a.start < b.start }
                return a.title < b.title
            }
        }
        if events != result { events = result }
    }

    func events(on date: Date, includeAllDay: Bool) -> [DayEvent] {
        let list = events[calendar.startOfDay(for: date)] ?? []
        return includeAllDay ? list : list.filter { !$0.allDay }
    }

    /// Ближайшее событие сегодня, которое ещё не началось.
    var nextEventToday: DayEvent? {
        let now = Date()
        return events(on: now, includeAllDay: false).first { $0.start > now }
    }

    func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) {
            month = next
            reload()
        }
    }

    func goToday() {
        dayChanged()
        selected = today
        month = today
        reload()
    }

    func select(_ date: Date) {
        selected = date
        if !calendar.isDate(date, equalTo: month, toGranularity: .month) {
            month = date
            reload()
        }
    }

    var writableCalendars: [CalendarInfo] { calendars.filter(\.writable) }

    var defaultCalendarID: String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier ?? writableCalendars.first?.id
    }

    func addEvent(title: String, start: Date, end: Date, allDay: Bool, calendarID: String?) -> Bool {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = allDay
        event.startDate = allDay ? calendar.startOfDay(for: start) : start
        event.endDate = allDay ? calendar.startOfDay(for: start) : max(end, start)
        event.calendar = calendarID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
        guard event.calendar != nil else {
            saveError = "Нет календаря, в который можно записать событие."
            return false
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            saveError = nil
            reload()
            return true
        } catch {
            saveError = "Не удалось сохранить: \(error.localizedDescription)"
            return false
        }
    }

    func open(_ event: DayEvent) {
        if let url = URL(string: "ical://ekevent/\(event.eventID)?method=show&options=more"),
           NSWorkspace.shared.open(url) { return }
        openCalendarApp()
    }

    func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

struct CalendarModuleView: View {
    @Environment(AppState.self) private var app
    @State private var adding = false
    @State private var newTitle = ""
    @State private var newStart = Date()
    @State private var newEnd = Date()
    @State private var newAllDay = false
    @State private var newCalendar = ""

    private var model: CalendarModel { app.calendar }
    private var prefs: Prefs { app.prefs }
    private var showEvents: Bool { prefs.isOn(.calEvents) }

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        // Именно так, без шаблона локали: русский шаблон дописывает «г.» после года.
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d MMMM EEEE")
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        // Месяц и год стоят в заголовке блока: отдельная строка под ним дублировала заголовок.
        ModuleSection(
            id: .calendar,
            title: Self.monthTitle.string(from: model.month).capitalized(with: .autoupdatingCurrent)
        ) {
            if !prefs.collapsed.contains(.calendar) { navigation }
        } content: {
            grid
            if showEvents {
                if model.access == .denied {
                    Hint("Чтобы видеть события, разрешите SinCombo доступ к календарям.")
                    LinkRow("Открыть настройки доступа…") { SystemSettings.privacyCalendars.open() }
                } else {
                    eventList
                }
            }
            if prefs.isOn(.calSettings) {
                LinkRow("Открыть «Календарь»…") { model.openCalendarApp() }
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 2) {
            Button("Сегодня") { model.goToday() }.buttonStyle(.link).font(.callout)
            Button { model.shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                .buttonStyle(.plain).accessibilityLabel("Предыдущий месяц")
            Button { model.shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                .buttonStyle(.plain).accessibilityLabel("Следующий месяц")
        }
    }

    private var grid: some View {
        let showWeeks = prefs.isOn(.calWeeks)
        let headers = CalendarGrid.weekdayHeaders(calendar: model.calendar)
        return Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                if showWeeks { Text("").frame(width: 20) }
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header.title)
                        .font(.caption2)
                        .foregroundStyle(header.isWeekend ? Color.red : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(model.weeks) { week in
                GridRow {
                    if showWeeks {
                        Text("\(week.number)").font(.caption2).foregroundStyle(.secondary).frame(width: 20)
                    }
                    ForEach(week.days) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: GridDay) -> some View {
        let isToday = model.calendar.isDate(day.date, inSameDayAs: model.today)
        let isSelected = model.calendar.isDate(day.date, inSameDayAs: model.selected)
        let dots = showEvents ? dotColors(day.date) : []
        return Button { model.select(day.date) } label: {
            VStack(spacing: 1) {
                Text("\(day.day)")
                    .font(.callout)
                    .monospacedDigit()
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(isToday ? Color.white : day.isWeekend ? Color.red : Color.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
                HStack(spacing: 2) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .opacity(day.inMonth ? 1 : 0.4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    // Сегодняшний день уже выделен кругом; рамка нужна только другому выбранному дню.
                    .strokeBorder(Color.accentColor, lineWidth: isSelected && !isToday ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dotColors(_ date: Date) -> [Color] {
        var colors: [Color] = []
        for event in model.events(on: date, includeAllDay: prefs.isOn(.calAllDay)) where !colors.contains(event.color) {
            colors.append(event.color)
            if colors.count == 3 { break }
        }
        return colors
    }

    @ViewBuilder private var eventList: some View {
        let isToday = model.calendar.isDate(model.selected, inSameDayAs: model.today)
        let list = model.events(on: model.selected, includeAllDay: prefs.isOn(.calAllDay))
        HStack {
            SubTitle(
                (isToday ? "Сегодня, " : "") + Self.dayTitle.string(from: model.selected)
                    + (list.isEmpty && model.access == .granted && !adding ? " — событий нет" : "")
            )
            Spacer(minLength: 0)
            if model.access == .granted {
                Button { toggleForm() } label: { Image(systemName: adding ? "xmark" : "plus").frame(width: 22, height: 22) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(adding ? "Отменить" : "Новое событие")
            }
        }
        if adding { form }
        if list.isEmpty, model.access != .granted {
            Hint("Запрашиваем доступ к календарям…")
        }
        ForEach(list) { event in
            let past = isToday && !event.allDay && event.end <= Date()
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
                Text(event.allDay ? "весь день" : Self.time.string(from: event.start) + "–" + Self.time.string(from: event.end))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Button { model.open(event) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).lineLimit(2).multilineTextAlignment(.leading)
                        if let place = event.location {
                            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let link = event.link, !past {
                    Button("Подключиться") { NSWorkspace.shared.open(link) }
                        .controlSize(.small)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .opacity(past ? 0.5 : 1)
        }
    }

    private func toggleForm() {
        adding.toggle()
        guard adding else { return }
        let calendar = model.calendar
        let base = calendar.startOfDay(for: model.selected)
        let hour = calendar.component(.hour, from: Date())
        newStart = calendar.date(byAdding: .hour, value: min(hour + 1, 23), to: base) ?? model.selected
        newEnd = newStart.addingTimeInterval(3600)
        newTitle = ""
        newAllDay = false
        newCalendar = model.defaultCalendarID ?? ""
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Новое событие", text: $newTitle).textFieldStyle(.roundedBorder)
            Toggle("Весь день", isOn: $newAllDay)
            if !newAllDay {
                DatePicker("Начало", selection: $newStart, displayedComponents: [.hourAndMinute])
                DatePicker("Конец", selection: $newEnd, displayedComponents: [.hourAndMinute])
            }
            if model.writableCalendars.count > 1 {
                Picker("Календарь", selection: $newCalendar) {
                    ForEach(model.writableCalendars) { Text($0.title).tag($0.id) }
                }
            }
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Отмена") { adding = false }
                Button("Добавить") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.addEvent(
                        title: title.isEmpty ? "Новое событие" : title,
                        start: newStart, end: newEnd, allDay: newAllDay,
                        calendarID: newCalendar.isEmpty ? nil : newCalendar
                    ) {
                        adding = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
