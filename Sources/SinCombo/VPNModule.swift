import SwiftUI
import AppKit
import SinComboCore

/// Состояние строки VPN в панели.
enum RowState: Equatable {
    case off, connecting, on, disconnecting, failed

    var title: String {
        switch self {
        case .off: return "Отключено"
        case .connecting: return "Подключение…"
        case .on: return "Подключено"
        case .disconnecting: return "Отключение…"
        case .failed: return "Не удалось подключиться"
        }
    }

    var isOn: Bool { self == .on || self == .connecting }
    var isBusy: Bool { self == .connecting || self == .disconnecting }
}

struct SessionStats: Equatable {
    var seconds: Double = 0
    var rx: UInt64 = 0
    var tx: UInt64 = 0
}

@MainActor
@Observable
final class VPNModel {
        // MARK: - Состояние для интерфейса

    private(set) var services: [VPNService] = []
    private(set) var loaded = false
    /// Список VPN не удалось прочитать (scutil не отвечает или изменился формат вывода).
    private(set) var loadFailed = false
    private(set) var session: SessionStats?
    private(set) var store = StatsStore()
    private(set) var blink = false
    var panelOpen = false {
        didSet { if panelOpen, panelOpen != oldValue { kick() } }
    }

    private var attempts: [String: ConnectAttempt] = [:]
    private var stopping: [String: Date] = [:]
    private var failed: Set<String> = []

    // MARK: - Внутреннее

    @ObservationIgnored private var started = false
    @ObservationIgnored private var watcher: NetworkWatcher?
    @ObservationIgnored private var meter = TrafficMeter()
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var listFailures = 0
    @ObservationIgnored private var secondsSinceRefresh = 0
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var dirty = false

    private static let statsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SinCombo/vpn-stats.json")
    }()

    func start() {
        guard !started else { return }
        store = StatsStore.load(from: Self.statsURL)
        store.prune(now: Date())
        watcher = NetworkWatcher {
            Task { @MainActor in AppState.shared.vpn.kick() }
        }
        started = true
    }

    // MARK: - Опрос

    private var isTransitional: Bool {
        !attempts.isEmpty || !stopping.isEmpty
            || services.contains { $0.status == .connecting || $0.status == .disconnecting }
    }

    private var connectedIDs: [String] {
        services.filter { $0.status == .connected }.map(\.id)
    }

    /// Вызывается раз в секунду из AppState: решает, пора ли опрашивать систему. Панель открыта или идёт переключение —
    /// каждую секунду; иначе раз в 5 с плюс мгновенное обновление по уведомлениям сети.
    func tick() async {
        guard started else { return }
        secondsSinceRefresh += 1
        let period = (panelOpen || isTransitional) ? 1 : 5
        if secondsSinceRefresh >= period { await refresh() }

        if isTransitional {
            blink.toggle()
        } else if blink {
            blink = false
        }
    }

    /// Немедленное обновление по событию (сеть изменилась, панель открыли, нажали переключатель).
    func kick() {
        guard started else { return }
        Task { await refresh() }
    }

    private func refresh() async {
        if refreshing {
            refreshQueued = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshQueued = false
            secondsSinceRefresh = 0
            let result = await VPNControl.list()
            let list = ScutilParser.parseList(result.output)
            let unreadable = result.code != 0 || (list.isEmpty && ScutilParser.mentionsServices(result.output))
            if unreadable {
                // Один сбой не меняет картину; после двух подряд показываем ошибку чтения.
                listFailures += 1
                if listFailures >= 2, !loadFailed { loadFailed = true }
            } else {
                listFailures = 0
                if loadFailed { loadFailed = false }
                apply(list, now: Date())
            }
            if !loaded { loaded = true }
        } while refreshQueued
    }

    private func apply(_ list: [VPNService], now: Date) {
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for (id, attempt) in attempts {
            guard let service = byID[id] else {
                attempts[id] = nil
                continue
            }
            switch attempt.evaluate(status: service.status, now: now) {
            case let .pending(next):
                if next != attempt { attempts[id] = next }
            case .succeeded:
                attempts[id] = nil
            case .failed:
                attempts[id] = nil
                failed.insert(id)
            }
        }
        for (id, since) in stopping {
            let status = byID[id]?.status ?? .disconnected
            if status == .disconnected || status == .invalid || now.timeIntervalSince(since) > 10 {
                stopping[id] = nil
            }
        }
        for service in list where service.status == .connected && failed.contains(service.id) {
            failed.remove(service.id)
        }

        if services != list { services = list }
        sampleTraffic(now: now)
    }

    // MARK: - Переключение

    func rowState(_ service: VPNService) -> RowState {
        if stopping[service.id] != nil, service.status != .disconnected, service.status != .invalid {
            return .disconnecting
        }
        if attempts[service.id] != nil {
            return service.status == .connected ? .on : .connecting
        }
        switch service.status {
        case .connected: return .on
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .disconnected, .invalid: return failed.contains(service.id) ? .failed : .off
        }
    }

    func toggle(_ service: VPNService) {
        let id = service.id
        switch rowState(service) {
        case .disconnecting:
            return
        case .on, .connecting:
            // Выключение или отмена попытки подключения.
            attempts[id] = nil
            failed.remove(id)
            stopping[id] = Date()
            Task {
                _ = await VPNControl.stop(id)
                await refresh()
            }
        case .off, .failed:
            failed.remove(id)
            attempts[id] = ConnectAttempt(startedAt: Date())
            Task {
                let result = await VPNControl.start(id)
                if result.code != 0, !result.timedOut, attempts[id] != nil {
                    attempts[id] = nil
                    failed.insert(id)
                }
                await refresh()
            }
        }
    }

    var anyConnected: Bool { services.contains { $0.status == .connected } }
    var transitional: Bool { isTransitional }

    // MARK: - Статистика

    var today: DayStats { store.total(days: 1, endingAt: Date()) }
    var month: DayStats { store.total(days: 30, endingAt: Date()) }

    private func sampleTraffic(now: Date) {
        let ids = connectedIDs
        guard !ids.isEmpty else {
            if session != nil {
                session = nil
                meter.reset()
                lastSample = nil
                save()
            }
            return
        }
        if session == nil {
            session = SessionStats()
            meter.reset()
            lastSample = nil
        }

        // Интерфейсы подключённых VPN: сначала по данным системы, иначе — все активные туннели.
        var interfaces = Set(ids.compactMap { watcher?.interfaceName(serviceID: $0) })
        if interfaces.isEmpty { interfaces = InterfaceReader.activeTunnelInterfaces() }
        let counters = InterfaceReader.counters().filter { interfaces.contains($0.key) }
        let delta = meter.sample(counters)

        // Время между замерами; большой разрыв (сон Mac) не засчитывается.
        var elapsed = lastSample.map { now.timeIntervalSince($0) } ?? 0
        if elapsed < 0 || elapsed > 30 { elapsed = 0 }
        lastSample = now

        guard elapsed > 0 || delta != InterfaceCounters() else { return }
        session?.seconds += elapsed
        session?.rx += delta.rx
        session?.tx += delta.tx
        store.add(seconds: elapsed, rx: delta.rx, tx: delta.tx, at: now)
        dirty = true
        if now.timeIntervalSince(lastSave) >= 15 { save() }
    }

    func resetStats() {
        store.reset()
        if session != nil { session = SessionStats() }
        dirty = true
        save()
    }

    private func save() {
        guard dirty else { return }
        store.prune(now: Date())
        do {
            try store.save(to: Self.statsURL)
            dirty = false
            lastSave = Date()
        } catch {
            NSLog("SinCombo: не удалось сохранить статистику: \(error.localizedDescription)")
        }
    }

    /// Сохранение перед выходом и перед перезапуском для обновления.
    func flush() {
        save()
    }

}

struct VPNModuleView: View {
    @Environment(AppState.self) private var app

    private var model: VPNModel { app.vpn }
    private var prefs: Prefs { app.prefs }

    var body: some View {
        ModuleSection(id: .vpn) {
            EmptyView()
        } content: {
            if !model.loaded {
                ProgressView().controlSize(.small)
            } else if model.loadFailed {
                Hint("Не удалось прочитать список VPN. Управлять подключениями можно в «Системных настройках».")
            } else if model.services.isEmpty {
                Hint("VPN не настроен")
            } else {
                ForEach(model.services) { service in
                    row(service, state: model.rowState(service))
                }
            }
            if prefs.isOn(.vpnStats), model.loaded, !model.services.isEmpty {
                SubTitle("Статистика")
                if let session = model.session {
                    stat("Сессия", DurationFormat.clock(Int(session.seconds)), session.rx, session.tx)
                } else {
                    InfoRow("Сессия", "нет подключения")
                }
                let today = model.today
                let month = model.month
                stat("Сегодня", DurationFormat.short(Int(today.seconds)), today.rx, today.tx)
                stat("30 дней", DurationFormat.short(Int(month.seconds)), month.rx, month.tx)
            }
            if prefs.isOn(.vpnSettings) {
                LinkRow("Настройки VPN…") { SystemSettings.vpn.open() }
            }
        }
    }

    private func row(_ service: VPNService, state: RowState) -> some View {
        HStack(spacing: 9) {
            IconDot(symbol: "lock.shield", active: state == .on)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).lineLimit(2)
                HStack(spacing: 5) {
                    if state.isBusy {
                        ProgressView().controlSize(.mini)
                    } else if state == .failed {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                    }
                    Text(state.title).font(.caption).foregroundStyle(state == .off ? Color.secondary : Color.primary)
                }
            }
            Spacer(minLength: 0)
            Toggle(service.name, isOn: Binding(get: { state.isOn }, set: { _ in model.toggle(service) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(state == .disconnecting)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func stat(_ title: String, _ time: String, _ rx: UInt64, _ tx: UInt64) -> some View {
        InfoRow(title, "\(time) · ↓ \(ByteFormat.string(rx)) · ↑ \(ByteFormat.string(tx))")
    }
}
