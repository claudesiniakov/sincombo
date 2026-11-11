import SwiftUI
import CoreWLAN
import CoreLocation
import SinComboCore

@MainActor
@Observable
final class WiFiModel {
    private(set) var available = true
    private(set) var power = false
    private(set) var current: String?
    private(set) var networks: [WiFiNetwork] = []
    private(set) var busy: String?
    private(set) var errorSSID: String?
    private(set) var errorText: String?
    private(set) var locationDenied = false
    private(set) var scanned = false
    var passwordFor: String?
    var otherOpen = false

    @ObservationIgnored private let client = CWWiFiClient.shared()
    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private var found: [String: CWNetwork] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var askedLocation = false

    private var interface: CWInterface? { client.interface() }

    /// Имена сетей macOS отдаёт только с доступом к геолокации.
    private func checkLocation() {
        switch location.authorizationStatus {
        case .notDetermined:
            if !askedLocation {
                askedLocation = true
                location.requestWhenInUseAuthorization()
            }
            locationDenied = false
        case .denied, .restricted:
            locationDenied = true
        default:
            locationDenied = false
        }
    }

    /// Быстрое чтение состояния без сканирования.
    func readState() {
        guard let interface else {
            available = false
            return
        }
        available = true
        let on = interface.powerOn()
        if power != on { power = on }
        let ssid = on ? interface.ssid() : nil
        if current != ssid { current = ssid }
    }

    func refresh() {
        checkLocation()
        readState()
        guard power, !scanning, let interface else {
            if !power { networks = [] }
            return
        }
        scanning = true
        let box = Unchecked(value: interface)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Unchecked<([CWNetwork], Set<String>)> in
                let scan = (try? box.value.scanForNetworks(withName: nil)) ?? []
                let profiles = box.value.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
                return Unchecked(value: (Array(scan), Set(profiles.compactMap(\.ssid))))
            }.value
            self.scanning = false
            self.scanned = true
            let (scan, known) = result.value
            var byName: [String: CWNetwork] = [:]
            var list: [WiFiNetwork] = []
            for network in scan {
                guard let ssid = network.ssid, !ssid.isEmpty else { continue }
                if let existing = byName[ssid], existing.rssiValue >= network.rssiValue { continue }
                byName[ssid] = network
            }
            for (ssid, network) in byName {
                list.append(WiFiNetwork(
                    ssid: ssid,
                    rssi: network.rssiValue,
                    secured: !network.supportsSecurity(.none),
                    known: known.contains(ssid)
                ))
            }
            self.found = byName
            self.readState()
            let arranged = WiFiNetwork.arrange(list, current: self.current)
            if self.networks != arranged { self.networks = arranged }
        }
    }

    func setPower(_ on: Bool) {
        guard let interface else { return }
        do {
            try interface.setPower(on)
            power = on
            errorSSID = nil
            errorText = nil
        } catch {
            errorSSID = ""
            errorText = "Не удалось переключить Wi-Fi: \(error.localizedDescription)"
        }
        passwordFor = nil
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.refresh()
        }
    }

    /// Нажатие на сеть: известная или открытая подключается сразу, для новой защищённой
    /// сначала показывается поле пароля.
    func select(_ network: WiFiNetwork) {
        guard busy == nil, network.ssid != current else { return }
        if network.secured && !network.known {
            passwordFor = passwordFor == network.ssid ? nil : network.ssid
            errorSSID = nil
            errorText = nil
            return
        }
        join(network, password: nil)
    }

    func join(_ network: WiFiNetwork, password: String?) {
        guard busy == nil, let interface, let target = found[network.ssid] else { return }
        if let password, network.secured, password.count < 8 {
            errorSSID = network.ssid
            errorText = "Пароль короче 8 символов. Проверьте и введите снова."
            return
        }
        busy = network.ssid
        errorSSID = nil
        errorText = nil
        let box = Unchecked(value: (interface, target))
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try box.value.0.associate(to: box.value.1, password: password)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            self.busy = nil
            if let failure {
                self.errorSSID = network.ssid
                if network.secured && password == nil {
                    // Сохранённый пароль системе получить не удалось — просим ввести.
                    self.passwordFor = network.ssid
                    self.errorText = "Введите пароль сети."
                } else {
                    self.errorText = "Не удалось подключиться: \(failure)"
                }
            } else {
                self.passwordFor = nil
            }
            self.refresh()
        }
    }
}

struct WiFiModuleView: View {
    @Environment(AppState.self) private var app
    @State private var password = ""

    private var model: WiFiModel { app.wifi }
    private var prefs: Prefs { app.prefs }

    var body: some View {
        ModuleSection(id: .wifi) {
            if model.available {
                Toggle("Wi-Fi", isOn: Binding(get: { model.power }, set: { model.setPower($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        } content: {
            if !model.available {
                Hint("Адаптер Wi-Fi не найден")
            } else if !model.power {
                Hint("Wi-Fi выключен")
            } else {
                list
            }
            if model.errorSSID == "", let text = model.errorText {
                Text(text).font(.caption).foregroundStyle(.red)
            }
            if prefs.isOn(.wifiSettings) {
                LinkRow("Настройки Wi-Fi…") { SystemSettings.wifi.open() }
            }
        }
    }

    @ViewBuilder private var list: some View {
        if model.locationDenied {
            Hint("Чтобы видеть имена сетей, разрешите SinCombo доступ к геолокации.")
            LinkRow("Открыть настройки геолокации…") { SystemSettings.privacyLocation.open() }
        }
        let known = model.networks.filter { $0.known || $0.ssid == model.current }
        let shownKnown = known.filter { prefs.isOn(.wifiKnown) || $0.ssid == model.current || $0.ssid == model.busy }
        let other = model.networks.filter { !$0.known && $0.ssid != model.current }
        if let current = model.current, !known.contains(where: { $0.ssid == current }) {
            // Сканирование ещё не дошло до текущей сети — показываем её по имени.
            row(WiFiNetwork(ssid: current, rssi: -60, secured: true, known: true))
        }
        ForEach(shownKnown) { row($0) }
        if model.current == nil && shownKnown.isEmpty && model.scanned && !model.locationDenied {
            Hint("Нет подключения")
        }
        if !model.scanned && model.networks.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Поиск сетей…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if prefs.isOn(.wifiOther), !other.isEmpty {
            RowButton(action: { model.otherOpen.toggle() }) {
                Text("Другие сети (\(other.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: model.otherOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.otherOpen {
                ForEach(other) { row($0) }
            }
        }
    }

    @ViewBuilder private func row(_ network: WiFiNetwork) -> some View {
        let isCurrent = network.ssid == model.current
        RowButton(action: { model.select(network) }) {
            IconDot(symbol: "wifi", active: isCurrent)
            Text(network.ssid).lineLimit(1)
            Spacer(minLength: 0)
            if model.busy == network.ssid {
                ProgressView().controlSize(.mini)
            }
            if network.secured {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Color.primary.opacity(0.65))
            }
            Image(systemName: "wifi", variableValue: Double(WiFiLogic.bars(rssi: network.rssi)) / 4)
                .font(.callout).foregroundStyle(.primary)
                .accessibilityLabel("Сигнал \(WiFiLogic.bars(rssi: network.rssi)) из 4")
        }
        if model.passwordFor == network.ssid {
            HStack(spacing: 6) {
                SecureField("Пароль", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit(network) }
                Button("Подключиться") { submit(network) }
            }
            .controlSize(.small)
            .padding(.leading, 32)
        }
        if model.errorSSID == network.ssid, let text = model.errorText {
            Text(text).font(.caption).foregroundStyle(.red).padding(.leading, 32)
        }
    }

    private func submit(_ network: WiFiNetwork) {
        model.join(network, password: password)
        password = ""
    }
}
