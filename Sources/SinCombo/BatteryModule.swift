import SwiftUI
import IOKit
import IOKit.ps
import SinComboCore

struct BatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    /// Минуты до разряда или до полной зарядки; ≤ 0 — система ещё считает.
    var minutes: Int
    var watts: Int?
    var health: Int?
    var cycles: Int?
    var lowPower: Bool
}

@MainActor
@Observable
final class BatteryModel {
    /// `nil` — у этого Mac нет аккумулятора.
    private(set) var state: BatteryState?

    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in AppState.shared.battery.reload() }
        }, nil)
        if let source = source?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppState.shared.battery.reload() }
        }
        reload()
    }

    func reload() {
        let next = Self.read()
        if state != next { state = next }
    }

    private static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery" else { continue }
            let current = description["Current Capacity"] as? Int ?? 0
            let maximum = description["Max Capacity"] as? Int ?? 100
            let charging = description["Is Charging"] as? Bool ?? false
            let onAC = description["Power Source State"] as? String == "AC Power"
            let minutes = (charging ? description["Time to Full Charge"] : description["Time to Empty"]) as? Int ?? -1
            var state = BatteryState(
                percent: maximum > 0 ? min(100, Int((Double(current) / Double(maximum) * 100).rounded())) : 0,
                charging: charging, onAC: onAC, minutes: minutes,
                watts: nil, health: nil, cycles: nil,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            if onAC, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                state.watts = adapter["Watts"] as? Int
            }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func number(_ key: String) -> Int? {
                    (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? NSNumber)?.intValue
                }
                state.cycles = number("CycleCount")
                if let raw = number("AppleRawMaxCapacity"), let design = number("DesignCapacity") {
                    state.health = BatteryFormat.health(rawMax: raw, design: design)
                }
            }
            return state
        }
        return nil
    }
}

struct BatteryModuleView: View {
    @Environment(AppState.self) private var app

    private var prefs: Prefs { app.prefs }

    var body: some View {
        if let state = app.battery.state {
            ModuleSection(id: .battery) {
                Text("\(state.percent) %").font(.callout).monospacedDigit().foregroundStyle(Color.primary.opacity(0.75))
            } content: {
                Meter(fraction: Double(state.percent) / 100, warn: state.percent <= 20 && !state.charging)
                    .accessibilityLabel("Заряд \(state.percent) %")
                if !prefs.isOn(.batOnlyBar) {
                    InfoRow("Источник питания", state.onAC ? (state.watts.map { "Адаптер \($0) Вт" } ?? "Адаптер") : "Аккумулятор")
                    if prefs.isOn(.batTime) {
                        if state.charging {
                            InfoRow("До полной зарядки", BatteryFormat.time(minutes: state.minutes))
                        } else if !state.onAC {
                            InfoRow("Осталось", BatteryFormat.time(minutes: state.minutes))
                        } else {
                            InfoRow("Состояние", state.percent >= 100 ? "Заряжен" : "Не заряжается")
                        }
                    }
                    InfoRow("Режим энергосбережения", state.lowPower ? "Включён" : "Выключен")
                    if prefs.isOn(.batHealth) {
                        if let health = state.health { InfoRow("Максимальная ёмкость", "\(health) %") }
                        if let cycles = state.cycles { InfoRow("Циклов зарядки", "\(cycles)") }
                    }
                    if prefs.isOn(.batSettings) {
                        LinkRow("Настройки аккумулятора…") { SystemSettings.battery.open() }
                    }
                }
            }
        }
    }
}
