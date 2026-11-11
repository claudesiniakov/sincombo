import SwiftUI
import Security
import SinComboCore

/// Ключи API хранятся в связке ключей macOS, не в файлах настроек.
enum Keychain {
    private static let service = "com.claudesiniakov.sincombo.apikey"

    static func set(_ secret: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        read(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func read(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}

struct UsageFailure: Error {
    let text: String
}

/// Запросы лимитов к сервисам. Идут только на серверы самих сервисов.
enum UsageFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "SinCombo"]
        return URLSession(configuration: config)
    }()

    private static func load(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageFailure(text: "нет связи с сервисом")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 401, 403: throw UsageFailure(text: "сервис отклонил ключ или вход (код \(code))")
        case 429: throw UsageFailure(text: "слишком частые запросы, повторите позже")
        default: throw UsageFailure(text: "сервис ответил кодом \(code)")
        }
    }

    private static var monthStartUTC: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private static func costLimit(_ usd: Double, limit: Double?) -> [UsageLimit] {
        if let limit, limit > 0 {
            return [UsageLimit(
                title: "Расход за месяц", fraction: usd / limit,
                caption: "\(MoneyFormat.usd(usd)) из \(MoneyFormat.usd(limit))"
            )]
        }
        return [UsageLimit(title: "Расход за месяц", fraction: nil, caption: MoneyFormat.usd(usd))]
    }

    /// Лимиты подписки Claude по входу Claude Code. Способ не документирован сервисом.
    static func claude() async throws -> [UsageLimit] {
        var raw = Keychain.read(service: "Claude Code-credentials", account: nil)
        if raw == nil {
            let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
            raw = try? Data(contentsOf: file)
        }
        guard let raw, let credentials = UsageParsers.claudeCodeToken(raw, now: Date()) else {
            throw UsageFailure(text: "вход Claude Code на этом Mac не найден")
        }
        if credentials.expired {
            throw UsageFailure(text: "вход Claude Code устарел — откройте Claude Code, он обновит вход")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let data = try await load(request)
        guard let limits = UsageParsers.claudeLimits(data, now: Date()) else {
            throw UsageFailure(text: "сервис ответил в неизвестном формате")
        }
        return limits
    }

    static func anthropic(key: String, limit: Double?) async throws -> [UsageLimit] {
        let start = ISO8601DateFormatter().string(from: monthStartUTC)
        var total = 0.0
        var page: String?
        for _ in 0..<6 {
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: start),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let data = try await load(request)
            guard let parsed = UsageParsers.anthropicCostUSD(data) else {
                throw UsageFailure(text: "сервис ответил в неизвестном формате")
            }
            total += parsed.usd
            page = parsed.nextPage
            if page == nil { break }
        }
        return costLimit(total, limit: limit)
    }

    static func openAI(key: String, limit: Double?) async throws -> [UsageLimit] {
        var total = 0.0
        var page: String?
        for _ in 0..<6 {
            var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            components.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(monthStartUTC.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let data = try await load(request)
            guard let parsed = UsageParsers.openAICostUSD(data) else {
                throw UsageFailure(text: "сервис ответил в неизвестном формате")
            }
            total += parsed.usd
            page = parsed.nextPage
            if page == nil { break }
        }
        return costLimit(total, limit: limit)
    }
}

@MainActor
@Observable
final class SubsModel {
    private static let key = "subscriptions.v1"
    /// Автоматический запрос — не чаще раза в 5 минут.
    private static let minInterval: TimeInterval = 300

    private(set) var subs: [Subscription] = []
    private(set) var limits: [UUID: [UsageLimit]] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var lastUpdate: Date?
    private(set) var loading = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Subscription].self, from: data) {
            subs = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(subs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    var hasRemote: Bool { subs.contains { $0.kind != .manual } }

    func add(_ sub: Subscription, key: String?) {
        subs.append(sub)
        if sub.kind.needsKey, let key, !key.isEmpty {
            Keychain.set(key, account: sub.id.uuidString)
        }
        save()
        refresh()
    }

    func remove(_ sub: Subscription) {
        subs.removeAll { $0.id == sub.id }
        limits[sub.id] = nil
        errors[sub.id] = nil
        if sub.kind.needsKey { Keychain.delete(account: sub.id.uuidString) }
        save()
    }

    func refreshIfDue() {
        if let lastUpdate, Date().timeIntervalSince(lastUpdate) < Self.minInterval { return }
        refresh()
    }

    func refresh() {
        guard !loading, hasRemote else { return }
        loading = true
        let list = subs.filter { $0.kind != .manual }
        Task {
            for sub in list {
                do {
                    let result: [UsageLimit]
                    switch sub.kind {
                    case .claudeCode:
                        result = try await UsageFetcher.claude()
                    case .anthropicAPI, .openAIAPI:
                        guard let key = Keychain.get(account: sub.id.uuidString) else {
                            throw UsageFailure(text: "ключ не найден в связке ключей — добавьте подписку заново")
                        }
                        result = sub.kind == .anthropicAPI
                            ? try await UsageFetcher.anthropic(key: key, limit: sub.monthlyLimit)
                            : try await UsageFetcher.openAI(key: key, limit: sub.monthlyLimit)
                    case .manual:
                        continue
                    }
                    self.limits[sub.id] = result
                    self.errors[sub.id] = nil
                } catch let failure as UsageFailure {
                    // Последние известные значения остаются на карточке.
                    self.errors[sub.id] = failure.text
                } catch {
                    self.errors[sub.id] = error.localizedDescription
                }
            }
            self.lastUpdate = Date()
            self.loading = false
        }
    }
}

struct SubsModuleView: View {
    @Environment(AppState.self) private var app

    private var model: SubsModel { app.subs }
    private var prefs: Prefs { app.prefs }

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d MMMM")
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ModuleSection(id: .subs) {
            EmptyView()
        } content: {
            let shown = model.subs.filter { $0.kind != .manual || prefs.isOn(.subsManual) }
            if model.subs.isEmpty {
                Hint("Подписок пока нет. Добавьте ключ API, вход Claude Code или подписку вручную.")
                LinkRow("Открыть настройки…") { SettingsWindow.show(tab: .modules) }
            } else if shown.isEmpty {
                Hint("Все подписки скрыты настройкой «Подписки без лимитов».")
            }
            ForEach(shown) { card($0) }
            if model.hasRemote {
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Обновить") { model.refresh() }
                        .buttonStyle(.link).font(.callout).disabled(model.loading)
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var status: String {
        if model.loading { return "Обновление…" }
        if let date = model.lastUpdate { return "Обновлено в " + Self.time.string(from: date) }
        return "Ещё не обновлялось"
    }

    @ViewBuilder private func card(_ sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(sub.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 0)
                Text(sub.kind.sourceLabel).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.limits[sub.id] ?? []) { limit in
                HStack {
                    Text(limit.title)
                    Spacer(minLength: 0)
                    if let fraction = limit.fraction {
                        Text("\(Int((fraction * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if let fraction = limit.fraction {
                    Meter(fraction: fraction, warn: fraction >= 0.7)
                        .accessibilityLabel("\(limit.title): \(Int((fraction * 100).rounded())) %")
                }
                if !limit.caption.isEmpty {
                    Text(limit.caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if sub.kind != .manual, model.limits[sub.id] == nil, model.errors[sub.id] == nil {
                Text(model.loading ? "Запрашиваем лимиты…" : "Данных пока нет").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errors[sub.id] {
                Text("Не удалось обновить: \(error)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sub.kind == .manual, prefs.isOn(.subsPeriod), let renewal = sub.renewal,
               let progress = PeriodProgress.compute(renewal: renewal, period: sub.period, now: Date(), calendar: .autoupdatingCurrent) {
                HStack {
                    Text("Оплаченный период")
                    Spacer(minLength: 0)
                    Text("\(Int((progress.fraction * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                Meter(fraction: progress.fraction, warn: progress.fraction >= 0.9)
                    .accessibilityLabel("Оплаченный период: \(Int((progress.fraction * 100).rounded())) %")
                Text("прошло \(progress.daysPassed) дн. из \(progress.daysTotal), осталось \(progress.daysLeft)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if prefs.isOn(.subsRenewal), let renewal = sub.renewal {
                let next = PeriodProgress.compute(renewal: renewal, period: sub.period, now: Date(), calendar: .autoupdatingCurrent)?.end ?? renewal
                Text("Продление " + Self.date.string(from: next) + (sub.price.isEmpty ? "" : ", " + sub.price))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}
