import Foundation

/// День в сетке месяца.
public struct GridDay: Equatable, Sendable, Identifiable {
    public let date: Date
    public let day: Int
    public let inMonth: Bool
    public let isWeekend: Bool

    public var id: Date { date }
}

public struct GridWeek: Equatable, Sendable, Identifiable {
    public let number: Int
    public let days: [GridDay]

    public var id: Date { days.first?.date ?? .distantPast }
}

/// Сетка месяца: целые недели, первый день недели — из календаря.
public enum CalendarGrid {
    public static func weeks(forMonthContaining date: Date, calendar: Calendar) -> [GridWeek] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start) else { return [] }
        var weeks: [GridWeek] = []
        var start = firstWeek.start
        while start < month.end, weeks.count < 6 {
            var days: [GridDay] = []
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                days.append(GridDay(
                    date: day,
                    day: calendar.component(.day, from: day),
                    inMonth: calendar.isDate(day, equalTo: month.start, toGranularity: .month),
                    isWeekend: calendar.isDateInWeekend(day)
                ))
            }
            weeks.append(GridWeek(number: calendar.component(.weekOfYear, from: start), days: days))
            guard let next = calendar.date(byAdding: .day, value: 7, to: start) else { break }
            start = next
        }
        return weeks
    }

    /// Короткие названия дней недели, начиная с первого дня недели календаря, и признак выходного.
    public static func weekdayHeaders(calendar: Calendar) -> [(title: String, isWeekend: Bool)] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols.isEmpty
            ? calendar.shortWeekdaySymbols : calendar.shortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return [] }
        // Опорная неделя: любая, от её начала берём 7 дней подряд.
        guard let week = calendar.dateInterval(of: .weekOfYear, for: Date(timeIntervalSince1970: 1_700_000_000)) else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            return (symbols[weekday - 1].lowercased(), calendar.isDateInWeekend(day))
        }
    }
}

/// Поиск ссылки на видеовстречу в полях события.
public enum MeetingLinks {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"')\]]*(?:zoom\.us/(?:j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|facetime\.apple\.com/join|telemost\.yandex\.ru/j/)[^\s<>"')\]]*"#,
        options: [.caseInsensitive]
    )

    public static func find(in fields: [String?]) -> URL? {
        for case let text? in fields {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range),
                  let r = Range(match.range, in: text) else { continue }
            var link = String(text[r])
            while let last = link.last, ".,;".contains(last) { link.removeLast() }
            if let url = URL(string: link) { return url }
        }
        return nil
    }
}
