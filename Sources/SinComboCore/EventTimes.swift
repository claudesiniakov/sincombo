import Foundation

/// Границы события, которые можно записать в EventKit.
///
/// Событие «на весь день» кончается в полночь следующего за последним дня: конец у EventKit
/// исключающий, поэтому однодневное событие — это `[00:00 дня, 00:00 следующего дня)`.
/// Обычное событие должно быть непустым: конец строго позже начала.
public enum EventTimes {
    public struct Bounds: Equatable, Sendable {
        public let start: Date
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    /// - Returns: `nil`, если обычное событие не имеет положительной длины или календарь
    ///   не смог отсчитать следующий день.
    public static func bounds(start: Date, end: Date, allDay: Bool, calendar: Calendar) -> Bounds? {
        if allDay {
            let day = calendar.startOfDay(for: start)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return Bounds(start: day, end: next)
        }
        guard end > start else { return nil }
        return Bounds(start: start, end: end)
    }
}
