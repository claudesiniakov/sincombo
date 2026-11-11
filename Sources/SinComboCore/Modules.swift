import Foundation

/// Модули панели. Порядок случаев — порядок по умолчанию.
public enum ModuleID: String, CaseIterable, Codable, Sendable, Identifiable {
    case calendar, sound, wifi, bluetooth, vpn, battery, subs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .calendar: return "Календарь"
        case .sound: return "Звук"
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .vpn: return "VPN"
        case .battery: return "Аккумулятор"
        case .subs: return "Подписки"
        }
    }

    public var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .sound: return "speaker.wave.2"
        case .wifi: return "wifi"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .vpn: return "lock.shield"
        case .battery: return "battery.75percent"
        case .subs: return "creditcard"
        }
    }
}

/// Состав и порядок модулей панели.
public struct PanelLayout: Codable, Equatable, Sendable {
    public private(set) var order: [ModuleID]
    public private(set) var disabled: Set<ModuleID>

    public init(order: [ModuleID] = ModuleID.allCases, disabled: Set<ModuleID> = []) {
        self.order = order
        self.disabled = disabled
        normalize()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Неизвестные значения (модуль из более новой версии) пропускаются, а не ломают настройки.
        let rawOrder = (try? c.decode([String].self, forKey: .order)) ?? []
        let rawDisabled = (try? c.decode([String].self, forKey: .disabled)) ?? []
        order = rawOrder.compactMap(ModuleID.init(rawValue:))
        disabled = Set(rawDisabled.compactMap(ModuleID.init(rawValue:)))
        normalize()
    }

    /// Убирает повторы, добавляет в конец модули, которых не было в сохранённом порядке,
    /// и не даёт выключить все модули сразу.
    private mutating func normalize() {
        var seen = Set<ModuleID>()
        order = order.filter { seen.insert($0).inserted }
        for id in ModuleID.allCases where !seen.contains(id) { order.append(id) }
        if disabled.count >= order.count, let first = order.first { disabled.remove(first) }
    }

    public var visible: [ModuleID] { order.filter { !disabled.contains($0) } }

    public func isEnabled(_ id: ModuleID) -> Bool { !disabled.contains(id) }

    /// Последний включённый модуль выключить нельзя.
    public func canDisable(_ id: ModuleID) -> Bool {
        isEnabled(id) && visible.count > 1
    }

    public mutating func setEnabled(_ id: ModuleID, _ enabled: Bool) {
        if enabled {
            disabled.remove(id)
        } else if canDisable(id) {
            disabled.insert(id)
        }
    }

    /// Перемещение в стиле SwiftUI `onMove`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().compactMap { order.indices.contains($0) ? order[$0] : nil }
        guard !moving.isEmpty else { return }
        let before = source.filter { $0 < destination }.count
        var rest = order
        for index in source.sorted(by: >) where rest.indices.contains(index) { rest.remove(at: index) }
        let target = min(max(0, destination - before), rest.count)
        rest.insert(contentsOf: moving, at: target)
        order = rest
    }

    public mutating func move(_ id: ModuleID, by delta: Int) {
        guard let index = order.firstIndex(of: id) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }
}
