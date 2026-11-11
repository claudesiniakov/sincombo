import Foundation

public enum WiFiLogic {
    /// Число делений значка сигнала (1–4) по уровню RSSI в дБм.
    public static func bars(rssi: Int) -> Int {
        if rssi >= -55 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -78 { return 2 }
        return 1
    }
}

/// Сеть Wi-Fi из сканирования.
public struct WiFiNetwork: Equatable, Sendable, Identifiable {
    public let ssid: String
    public let rssi: Int
    public let secured: Bool
    public let known: Bool

    public var id: String { ssid }

    public init(ssid: String, rssi: Int, secured: Bool, known: Bool) {
        self.ssid = ssid
        self.rssi = rssi
        self.secured = secured
        self.known = known
    }

    /// Одна строка на имя сети (берётся точка с лучшим сигналом), текущая сеть первой,
    /// остальные — по убыванию сигнала.
    public static func arrange(_ networks: [WiFiNetwork], current: String?) -> [WiFiNetwork] {
        var best: [String: WiFiNetwork] = [:]
        for network in networks where !network.ssid.isEmpty {
            if let existing = best[network.ssid], existing.rssi >= network.rssi { continue }
            best[network.ssid] = network
        }
        return best.values.sorted { a, b in
            if (a.ssid == current) != (b.ssid == current) { return a.ssid == current }
            if a.rssi != b.rssi { return a.rssi > b.rssi }
            return a.ssid.localizedCaseInsensitiveCompare(b.ssid) == .orderedAscending
        }
    }
}

/// Заряд устройств Bluetooth из `system_profiler SPBluetoothDataType -json`.
public enum BluetoothBattery {
    /// Адрес устройства (в верхнем регистре, через двоеточие) → подпись заряда.
    public static func parse(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for section in sections {
            for key in ["device_connected", "device_not_connected"] {
                guard let devices = section[key] as? [[String: Any]] else { continue }
                for entry in devices {
                    for (_, value) in entry {
                        guard let info = value as? [String: Any],
                              let address = info["device_address"] as? String else { continue }
                        if let label = label(info) { result[normalize(address)] = label }
                    }
                }
            }
        }
        return result
    }

    public static func normalize(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    static func label(_ info: [String: Any]) -> String? {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let digits = raw.filter(\.isNumber)
            return digits.isEmpty ? nil : digits + " %"
        }
        var parts: [String] = []
        if let left = value("device_batteryLevelLeft") { parts.append("Л " + left) }
        if let right = value("device_batteryLevelRight") { parts.append("П " + right) }
        if let box = value("device_batteryLevelCase") { parts.append("футляр " + box) }
        if parts.isEmpty, let main = value("device_batteryLevelMain") { parts.append(main) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum BatteryFormat {
    /// Оставшееся время в минутах: «6 ч 40 мин», «48 мин»; отрицательное или нулевое — «Расчёт…».
    public static func time(minutes: Int) -> String {
        guard minutes > 0 else { return "Расчёт…" }
        return DurationFormat.short(minutes * 60)
    }

    /// Максимальная ёмкость в процентах от проектной.
    public static func health(rawMax: Int, design: Int) -> Int? {
        guard rawMax > 0, design > 0 else { return nil }
        return min(100, Int((Double(rawMax) / Double(design) * 100).rounded()))
    }
}
