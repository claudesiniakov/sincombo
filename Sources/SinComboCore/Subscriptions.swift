import Foundation

/// Откуда берутся данные подписки.
public enum SubscriptionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Введена вручную: название, цена, дата продления.
    case manual
    /// Лимиты подписки Claude через вход Claude Code на этом Mac.
    case claudeCode
    /// Расход Anthropic API за месяц (ключ администратора).
    case anthropicAPI
    /// Расход OpenAI API за месяц (ключ администратора).
    case openAIAPI
    /// Баланс DeepSeek API (ключ).
    case deepSeek

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: return "Вручную"
        case .claudeCode: return "Подписка Claude (вход Claude Code)"
        case .anthropicAPI: return "Anthropic API (ключ)"
        case .openAIAPI: return "OpenAI API (ключ)"
        case .deepSeek: return "DeepSeek API (ключ)"
        }
    }

    public var sourceLabel: String {
        switch self {
        case .manual: return "вручную"
        case .claudeCode: return "вход Claude Code"
        case .anthropicAPI, .openAIAPI, .deepSeek: return "ключ API"
        }
    }

    public var needsKey: Bool { self == .anthropicAPI || self == .openAIAPI || self == .deepSeek }

    /// Месячный лимит расхода есть только у сервисов, которые отдают расход за месяц.
    public var supportsMonthlyLimit: Bool { self == .anthropicAPI || self == .openAIAPI }
}

public enum BillingPeriod: String, Codable, Sendable, CaseIterable, Identifiable {
    case month, year

    public var id: String { rawValue }
    public var title: String { self == .month ? "Месяц" : "Год" }
}

public struct Subscription: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: SubscriptionKind
    /// Цена для показа рядом с датой продления, например «20 $».
    public var price: String
    public var renewal: Date?
    public var period: BillingPeriod
    /// Месячный лимит расхода в долларах — для полосы у подписок с ключом API.
    public var monthlyLimit: Double?

    public init(
        id: UUID = UUID(), name: String, kind: SubscriptionKind, price: String = "",
        renewal: Date? = nil, period: BillingPeriod = .month, monthlyLimit: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.price = price
        self.renewal = renewal
        self.period = period
        self.monthlyLimit = monthlyLimit
    }
}

/// Один лимит на карточке подписки.
public struct UsageLimit: Equatable, Sendable, Identifiable {
    public let title: String
    /// Доля расхода 0…1; `nil` — известна только сумма.
    public let fraction: Double?
    public let caption: String

    public var id: String { title }

    public init(title: String, fraction: Double?, caption: String) {
        self.title = title
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.caption = caption
    }
}

/// Оплаченный период ручной подписки: сколько прошло и сколько осталось до продления.
public struct PeriodProgress: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let daysTotal: Int
    public let daysPassed: Int

    public var daysLeft: Int { max(0, daysTotal - daysPassed) }
    public var fraction: Double { daysTotal > 0 ? min(1, max(0, Double(daysPassed) / Double(daysTotal))) : 0 }

    /// Дата продления в прошлом переносится вперёд на целое число периодов.
    public static func compute(renewal: Date, period: BillingPeriod, now: Date, calendar: Calendar) -> PeriodProgress? {
        let component: Calendar.Component = period == .month ? .month : .year
        let today = calendar.startOfDay(for: now)
        let anchor = calendar.startOfDay(for: renewal)
        var end = anchor
        var steps = 0
        // Шаги считаются от исходной даты: 31 января + 1 месяц + 1 месяц не должно «съезжать» на 28-е.
        while end <= today, steps < 2000 {
            steps += 1
            guard let next = calendar.date(byAdding: component, value: steps, to: anchor) else { return nil }
            end = next
        }
        guard let start = calendar.date(byAdding: component, value: steps - 1, to: anchor) else { return nil }
        let total = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        let passed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        guard total > 0 else { return nil }
        return PeriodProgress(start: start, end: end, daysTotal: total, daysPassed: min(max(0, passed), total))
    }
}

/// Разбор ответов сервисов. Форматы взяты из их документации и не гарантированы навсегда:
/// при любой неожиданности разбор возвращает `nil`, а карточка показывает ошибку.
public enum UsageParsers {
    /// Ответ `GET /v1/organizations/cost_report` (Anthropic): суммы — строки в центах.
    public static func anthropicCostUSD(_ data: Data) -> (usd: Double, nextPage: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]] else { return nil }
        var cents = 0.0
        for bucket in buckets {
            for item in bucket["results"] as? [[String: Any]] ?? [] {
                if let text = item["amount"] as? String, let value = Double(text) {
                    cents += value
                } else if let value = item["amount"] as? Double {
                    cents += value
                }
            }
        }
        let more = root["has_more"] as? Bool ?? false
        return (cents / 100, more ? root["next_page"] as? String : nil)
    }

    /// Ответ `GET /v1/organization/costs` (OpenAI): суммы — доллары в `amount.value`.
    public static func openAICostUSD(_ data: Data) -> (usd: Double, nextPage: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]] else { return nil }
        var usd = 0.0
        for bucket in buckets {
            for item in bucket["results"] as? [[String: Any]] ?? [] {
                guard let amount = item["amount"] as? [String: Any] else { continue }
                if let value = amount["value"] as? Double {
                    usd += value
                } else if let text = amount["value"] as? String, let value = Double(text) {
                    usd += value
                }
            }
        }
        let more = root["has_more"] as? Bool ?? false
        return (usd, more ? root["next_page"] as? String : nil)
    }

    /// Ответ `GET /user/balance` (DeepSeek): остаток в валюте и доступность запросов.
    /// Строки вида «110.00», поэтому числа разбираются и из строки, и из JSON-числа.
    public static func deepSeekBalance(_ data: Data) -> [UsageLimit]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]] else { return nil }
        var limits: [UsageLimit] = []
        for info in infos {
            guard let total = number(info["total_balance"]) else { continue }
            let currency = (info["currency"] as? String)?.uppercased() ?? "CNY"
            var caption = MoneyFormat.amount(total) + " " + currency
            if let topped = number(info["topped_up_balance"]), topped > 0 {
                caption += " · оплачено " + MoneyFormat.amount(topped)
            }
            if let granted = number(info["granted_balance"]), granted > 0 {
                caption += " · бонусы " + MoneyFormat.amount(granted)
            }
            limits.append(UsageLimit(title: "Баланс, " + currency, fraction: nil, caption: caption))
        }
        guard !limits.isEmpty else { return nil }
        if root["is_available"] as? Bool == false {
            limits.append(UsageLimit(title: "Состояние", fraction: nil, caption: "баланса не хватает для запросов"))
        }
        return limits
    }

    /// Лимиты подписки Claude: окна `five_hour`, `seven_day` и подобные с полями
    /// `utilization` (проценты) и `resets_at`.
    public static func claudeLimits(_ data: Data, now: Date) -> [UsageLimit]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let titles: [(key: String, title: String)] = [
            ("five_hour", "Сессия, 5 часов"),
            ("seven_day", "Неделя"),
            ("seven_day_opus", "Неделя, Opus"),
            ("seven_day_sonnet", "Неделя, Sonnet"),
        ]
        var limits: [UsageLimit] = []
        for (key, title) in titles {
            guard let window = root[key] as? [String: Any] else { continue }
            let percent: Double
            if let value = window["utilization"] as? Double {
                percent = value
            } else if let value = window["utilization"] as? Int {
                percent = Double(value)
            } else {
                continue
            }
            var caption = ""
            if let text = window["resets_at"] as? String, let date = parseDate(text) {
                caption = "сброс " + resetCaption(date, now: now)
            }
            limits.append(UsageLimit(title: title, fraction: percent / 100, caption: caption))
        }
        return limits.isEmpty ? nil : limits
    }

    /// Токен входа Claude Code из его записи учётных данных.
    public static func claudeCodeToken(_ data: Data, now: Date) -> (token: String, expired: Bool)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expired = false
        if let ms = oauth["expiresAt"] as? Double { expired = ms / 1000 <= now.timeIntervalSince1970 }
        return (token, expired)
    }

    static func number(_ raw: Any?) -> Double? {
        if let text = raw as? String {
            return Double(text.replacingOccurrences(of: ",", with: "."))
        }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func resetCaption(_ date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "скоро" }
        if seconds < 24 * 3600 { return "через " + DurationFormat.short(max(60, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, HH:mm"
        return formatter.string(from: date)
    }
}

public enum MoneyFormat {
    /// «12,40»
    public static func amount(_ value: Double) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// «12,40 $»
    public static func usd(_ value: Double) -> String {
        amount(value) + " $"
    }
}
