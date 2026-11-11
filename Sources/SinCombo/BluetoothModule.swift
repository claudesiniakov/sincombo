import SwiftUI
import IOBluetooth
import IOKit
import SinComboCore

/// Питание Bluetooth. Публичного API нет: используются функции настроек из IOBluetooth,
/// как в утилите blueutil. Если в новой системе их не окажется, переключатель скрывается.
enum BluetoothPower {
    private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    static var isOn: Bool? {
        guard let symbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: Getter.self)() != 0
    }

    static func set(_ on: Bool) -> Bool {
        guard let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return false }
        unsafeBitCast(symbol, to: Setter.self)(on ? 1 : 0)
        return true
    }
}

struct BluetoothDevice: Identifiable, Equatable {
    enum Kind { case headphones, mouse, keyboard, other }

    let id: String
    let name: String
    let kind: Kind
    let connected: Bool

    var symbol: String {
        switch kind {
        case .headphones: return "headphones"
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

@MainActor
@Observable
final class BluetoothModel {
    /// `nil` — состояние питания узнать не удалось.
    private(set) var power: Bool?
    private(set) var devices: [BluetoothDevice] = []
    private(set) var battery: [String: String] = [:]
    private(set) var busy: String?
    private(set) var errorID: String?

    @ObservationIgnored private var handles: [String: IOBluetoothDevice] = [:]
    @ObservationIgnored private var lastBattery = Date.distantPast
    @ObservationIgnored private var batteryLoading = false

    func refresh(withBattery: Bool) {
        let on = BluetoothPower.isOn
        if power != on { power = on }
        guard on != false else {
            if !devices.isEmpty { devices = [] }
            return
        }
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var list: [BluetoothDevice] = []
        var map: [String: IOBluetoothDevice] = [:]
        for device in paired {
            guard let address = device.addressString else { continue }
            let id = BluetoothBattery.normalize(address)
            map[id] = device
            list.append(BluetoothDevice(
                id: id,
                name: device.name ?? address,
                kind: Self.kind(major: device.deviceClassMajor, minor: device.deviceClassMinor),
                connected: device.isConnected()
            ))
        }
        list.sort { a, b in
            if a.connected != b.connected { return a.connected }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        handles = map
        if devices != list { devices = list }
        if withBattery { loadBattery() }
    }

    private static func kind(major: BluetoothDeviceClassMajor, minor: BluetoothDeviceClassMinor) -> BluetoothDevice.Kind {
        if major == 4 { return .headphones }
        if major == 5 {
            // Младшие биты подкласса периферии: 01 — клавиатура, 10 — указатель.
            let peripheral = (minor >> 4) & 0x3
            if peripheral == 1 { return .keyboard }
            if peripheral == 2 { return .mouse }
            if peripheral == 3 { return .keyboard }
        }
        return .other
    }

    /// Заряд читается из отчёта system_profiler — не чаще раза в минуту.
    private func loadBattery() {
        guard !batteryLoading, Date().timeIntervalSince(lastBattery) > 60 else { return }
        batteryLoading = true
        Task {
            let result = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 10)
            self.batteryLoading = false
            self.lastBattery = Date()
            guard result.code == 0 else { return }
            let parsed = BluetoothBattery.parse(Data(result.output.utf8))
            if self.battery != parsed { self.battery = parsed }
        }
    }

    func setPower(_ on: Bool) {
        guard BluetoothPower.set(on) else { return }
        power = on
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            self.lastBattery = .distantPast
            self.refresh(withBattery: false)
        }
    }

    func toggle(_ device: BluetoothDevice) {
        guard busy == nil, let handle = handles[device.id] else { return }
        busy = device.id
        errorID = nil
        let box = Unchecked(value: handle)
        let connect = !device.connected
        Task {
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                let status = connect ? box.value.openConnection() : box.value.closeConnection()
                return status == kIOReturnSuccess
            }.value
            try? await Task.sleep(for: .seconds(connect ? 1 : 0.5))
            self.busy = nil
            if !ok { self.errorID = device.id }
            self.lastBattery = .distantPast
            self.refresh(withBattery: true)
        }
    }
}

struct BluetoothModuleView: View {
    @Environment(AppState.self) private var app

    private var model: BluetoothModel { app.bluetooth }
    private var prefs: Prefs { app.prefs }

    var body: some View {
        ModuleSection(id: .bluetooth) {
            if let power = model.power {
                Toggle("Bluetooth", isOn: Binding(get: { power }, set: { model.setPower($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        } content: {
            if model.power == false {
                Hint("Bluetooth выключен")
            } else {
                let shown = model.devices.filter { $0.connected || prefs.isOn(.btDisconnected) }
                if shown.isEmpty {
                    Hint(model.devices.isEmpty ? "Нет сопряжённых устройств" : "Нет подключённых устройств")
                }
                ForEach(shown) { device in
                    RowButton(action: { model.toggle(device) }) {
                        IconDot(symbol: device.symbol, active: device.connected)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).lineLimit(1)
                            if device.connected, prefs.isOn(.btBattery), let level = model.battery[device.id] {
                                Text(level).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            if model.errorID == device.id {
                                Text("Не удалось подключиться").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer(minLength: 0)
                        if model.busy == device.id {
                            ProgressView().controlSize(.mini)
                        } else if device.connected {
                            Text("Подключено").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if prefs.isOn(.btSettings) {
                LinkRow("Настройки Bluetooth…") { SystemSettings.bluetooth.open() }
            }
        }
    }
}
