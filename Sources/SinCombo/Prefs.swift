import SwiftUI
import SinComboCore

/// Переключаемые параметры модулей.
enum Opt: String, CaseIterable, Codable {
    case wifiKnown, wifiOther, wifiSettings
    case btDisconnected, btBattery, btSettings
    case soundOutputs, soundInput, soundSettings
    case calEvents, calAllDay, calWeeks, calSettings
    case batOnlyBar, batTime, batHealth, batSettings
    case vpnStats, vpnSettings
    case subsRenewal, subsManual, subsPeriod
    case awakeDisplay

    var defaultValue: Bool {
        switch self {
        case .soundInput, .calWeeks, .batOnlyBar, .batHealth: return false
        default: return true
        }
    }

    var title: String {
        switch self {
        case .wifiKnown: return "Неподключённые известные сети"
        case .wifiOther: return "Другие сети"
        case .wifiSettings: return "Кнопка «Настройки Wi-Fi…»"
        case .btDisconnected: return "Неподключённые устройства"
        case .btBattery: return "Заряд устройств"
        case .btSettings: return "Кнопка «Настройки Bluetooth…»"
        case .soundOutputs: return "Устройства вывода"
        case .soundInput: return "Блок ввода (микрофон)"
        case .soundSettings: return "Кнопка «Настройки звука…»"
        case .calEvents: return "События"
        case .calAllDay: return "События на весь день"
        case .calWeeks: return "Номера недель"
        case .calSettings: return "Кнопка «Открыть Календарь…»"
        case .batOnlyBar: return "Только полоса заряда"
        case .batTime: return "Оставшееся время"
        case .batHealth: return "Состояние: ёмкость и циклы"
        case .batSettings: return "Кнопка «Настройки аккумулятора…»"
        case .vpnStats: return "Статистика"
        case .vpnSettings: return "Кнопка «Настройки VPN…»"
        case .subsRenewal: return "Даты продления"
        case .subsManual: return "Подписки без лимитов (введённые вручную)"
        case .subsPeriod: return "Полоса до даты продления у ручных подписок"
        case .awakeDisplay: return "Не гасить экран"
        }
    }
}

enum BarText: String, CaseIterable, Codable, Identifiable {
    case none, date, weekdayDate, nextEvent, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Нет"
        case .date: return "Дата"
        case .weekdayDate: return "День недели и дата"
        case .nextEvent: return "Ближайшее событие"
        case .battery: return "Заряд аккумулятора"
        }
    }
}

/// Настройки приложения. Меняются сразу, хранятся в UserDefaults одной записью.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()

    private struct Stored: Codable {
        var layout = PanelLayout()
        var collapsed: [String] = []
        var options: [String: Bool] = [:]
        var barText = BarText.none.rawValue
        var barVPN = false
        var barBattery = false
        /// Необязательное: в настройках версии 0.1.0 этого поля нет.
        var barAwake: Bool?
        var hiddenCalendars: [String] = []
    }

    private static let key = "prefs.v1"

    var layout: PanelLayout { didSet { save() } }
    var collapsed: Set<ModuleID> { didSet { save() } }
    private var options: [String: Bool] { didSet { save() } }
    var barText: BarText { didSet { save() } }
    var barVPN: Bool { didSet { save() } }
    var barBattery: Bool { didSet { save() } }
    var barAwake: Bool { didSet { save() } }
    var hiddenCalendars: Set<String> { didSet { save() } }

    private init() {
        var stored = Stored()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
        layout = stored.layout
        collapsed = Set(stored.collapsed.compactMap(ModuleID.init(rawValue:)))
        options = stored.options
        barText = BarText(rawValue: stored.barText) ?? .none
        barVPN = stored.barVPN
        barBattery = stored.barBattery
        barAwake = stored.barAwake ?? true
        hiddenCalendars = Set(stored.hiddenCalendars)
    }

    private func save() {
        let stored = Stored(
            layout: layout,
            collapsed: collapsed.map(\.rawValue).sorted(),
            options: options,
            barText: barText.rawValue,
            barVPN: barVPN,
            barBattery: barBattery,
            barAwake: barAwake,
            hiddenCalendars: hiddenCalendars.sorted()
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func isOn(_ option: Opt) -> Bool {
        options[option.rawValue] ?? option.defaultValue
    }

    func set(_ option: Opt, _ value: Bool) {
        options[option.rawValue] = value
    }

    func binding(_ option: Opt) -> Binding<Bool> {
        Binding(get: { self.isOn(option) }, set: { self.set(option, $0) })
    }

    func toggleCollapsed(_ id: ModuleID) {
        if collapsed.contains(id) {
            collapsed.remove(id)
        } else {
            collapsed.insert(id)
        }
    }

    func reset() {
        layout = PanelLayout()
        collapsed = []
        options = [:]
        barText = .none
        barVPN = false
        barBattery = false
        barAwake = true
        hiddenCalendars = []
    }
}

/// Разделы «Системных настроек».
enum SystemSettings {
    case wifi, bluetooth, sound, battery, vpn, privacyCalendars, privacyLocation, privacyBluetooth

    private var address: String {
        switch self {
        case .wifi: return "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case .bluetooth: return "x-apple.systempreferences:com.apple.BluetoothSettings"
        case .sound: return "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case .battery: return "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        case .vpn: return "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"
        case .privacyCalendars: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .privacyLocation: return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        case .privacyBluetooth: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        }
    }

    @MainActor
    func open() {
        if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

/// Обёртка для передачи системных объектов, не помеченных Sendable, в фоновую задачу.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}
