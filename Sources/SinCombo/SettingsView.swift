import SwiftUI
import AppKit
import EventKit
import CoreLocation
import SinComboCore

enum SettingsTab: Hashable { case modules, general, about }

/// Окно настроек. Создаётся вручную: у приложения без значка в Dock нет обычных окон.
@MainActor
enum SettingsWindow {
    static let title = "Настройки SinCombo"
    private static var window: NSWindow?
    static var tab: SettingsTab = .modules

    static func show(tab: SettingsTab) {
        Self.tab = tab
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView().environment(AppState.shared))
            let created = NSWindow(contentViewController: controller)
            created.title = title
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 480, height: 600))
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var tab = SettingsWindow.tab
    @State private var adding = false

    var body: some View {
        TabView(selection: $tab) {
            modules.tabItem { Label("Модули", systemImage: "square.stack.3d.up") }.tag(SettingsTab.modules)
            general.tabItem { Label("Основные", systemImage: "gearshape") }.tag(SettingsTab.general)
            about.tabItem { Label("О программе", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 480, height: 600)
        .sheet(isPresented: $adding) {
            AddSubscriptionView { adding = false }.environment(app)
        }
    }

    // MARK: - Модули

    private var modules: some View {
        let prefs = app.prefs
        return List {
            Section("Порядок и состав панели") {
                ForEach(prefs.layout.order) { id in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Image(systemName: id.symbol).frame(width: 20)
                        Text(id.title)
                        Spacer()
                        Button { prefs.layout.move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(prefs.layout.order.first == id)
                            .accessibilityLabel("\(id.title): выше")
                        Button { prefs.layout.move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(prefs.layout.order.last == id)
                            .accessibilityLabel("\(id.title): ниже")
                        Toggle(id.title, isOn: Binding(
                            get: { prefs.layout.isEnabled(id) },
                            set: { prefs.layout.setEnabled(id, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(prefs.layout.isEnabled(id) && !prefs.layout.canDisable(id))
                    }
                    .buttonStyle(.borderless)
                }
                .onMove { source, destination in
                    prefs.layout.move(fromOffsets: source, toOffset: destination)
                }
            }
            ForEach(prefs.layout.visible) { id in
                Section(id.title) {
                    options(for: id)
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func options(for id: ModuleID) -> some View {
        let prefs = app.prefs
        switch id {
        case .calendar:
            toggle(.calEvents)
            if prefs.isOn(.calEvents) {
                toggle(.calAllDay)
                if app.calendar.calendars.isEmpty {
                    Text("Список календарей появится после выдачи доступа.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(app.calendar.calendars) { info in
                    Toggle(isOn: Binding(
                        get: { !prefs.hiddenCalendars.contains(info.id) },
                        set: { shown in
                            if shown {
                                prefs.hiddenCalendars.remove(info.id)
                            } else {
                                prefs.hiddenCalendars.insert(info.id)
                            }
                            app.calendar.reload()
                        }
                    )) {
                        HStack(spacing: 6) {
                            Circle().fill(info.color).frame(width: 8, height: 8)
                            Text("Календарь «\(info.title)»")
                        }
                    }
                }
            }
            toggle(.calWeeks)
            toggle(.calSettings)
        case .sound:
            toggle(.soundOutputs)
            toggle(.soundInput)
            toggle(.soundSettings)
        case .wifi:
            toggle(.wifiKnown)
            toggle(.wifiOther)
            toggle(.wifiSettings)
        case .bluetooth:
            toggle(.btDisconnected)
            toggle(.btBattery)
            toggle(.btSettings)
        case .vpn:
            toggle(.vpnStats)
            toggle(.vpnSettings)
        case .battery:
            toggle(.batOnlyBar)
            if !prefs.isOn(.batOnlyBar) {
                toggle(.batTime)
                toggle(.batHealth)
                toggle(.batSettings)
            }
        case .subs:
            toggle(.subsRenewal)
            toggle(.subsManual)
            if prefs.isOn(.subsManual) { toggle(.subsPeriod) }
            ForEach(app.subs.subs) { sub in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sub.name)
                        Text(sub.kind.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Удалить") { app.subs.remove(sub) }.buttonStyle(.borderless)
                }
            }
            Button("Добавить подписку…") { adding = true }
        }
    }

    private func toggle(_ option: Opt) -> some View {
        Toggle(option.title, isOn: app.prefs.binding(option))
    }

    // MARK: - Основные

    private var general: some View {
        @Bindable var prefs = app.prefs
        @Bindable var updater = app.updater
        return Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }
                ))
                Toggle("Проверять обновления автоматически", isOn: $updater.autoCheck)
            }
            Section("Строка меню") {
                Picker("Текст рядом со значком", selection: $prefs.barText) {
                    ForEach(BarText.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Значок VPN в строке меню", isOn: $prefs.barVPN)
                Toggle("Значок аккумулятора в строке меню", isOn: $prefs.barBattery)
            }
            Section {
                Button("Сбросить настройки") { prefs.reset() }
            } footer: {
                Text("Подписки и ключи API при сбросе не удаляются.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - О программе

    private var about: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: MenuBarArt.gears(side: 44))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SinCombo \(app.updater.currentVersionString)").font(.headline)
                        Text("Wi-Fi, Bluetooth, звук, календарь, VPN, аккумулятор и подписки в одной панели")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(app.updater.statusLine)
                        .foregroundStyle(app.updater.isFailed ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let action = app.updater.actionTitle {
                        Button(action) { app.updater.primaryAction() }
                    }
                }
                Link("Репозиторий на GitHub", destination: URL(string: "https://github.com/claudesiniakov/sincombo")!)
            }
            Section("Системные разрешения") {
                permission("Календари", granted: calendarGranted) { SystemSettings.privacyCalendars.open() }
                permission("Службы геолокации (имена сетей Wi-Fi)", granted: locationGranted) {
                    SystemSettings.privacyLocation.open()
                }
                HStack {
                    Text("Bluetooth")
                    Spacer()
                    Button("Открыть настройки…") { SystemSettings.privacyBluetooth.open() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var calendarGranted: Bool? {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return true
        case .notDetermined: return nil
        default: return false
        }
    }

    private var locationGranted: Bool? {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: return nil
        case .denied, .restricted: return false
        default: return true
        }
    }

    private func permission(_ title: String, granted: Bool?, open: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted == true ? "Разрешено" : granted == false ? "Запрещено" : "Не запрошено")
                .foregroundStyle(granted == true ? Color.green : granted == false ? Color.red : Color.secondary)
            Button("Открыть настройки…", action: open)
        }
    }
}

/// Форма новой подписки.
struct AddSubscriptionView: View {
    @Environment(AppState.self) private var app
    let close: () -> Void

    @State private var kind = SubscriptionKind.manual
    @State private var name = ""
    @State private var key = ""
    @State private var limit = ""
    @State private var price = ""
    @State private var hasRenewal = true
    @State private var renewal = Date()
    @State private var period = BillingPeriod.month

    private var defaultName: String {
        switch kind {
        case .manual: return ""
        case .claudeCode: return "Claude"
        case .anthropicAPI: return "Anthropic API"
        case .openAIAPI: return "OpenAI API"
        }
    }

    private var valid: Bool {
        let title = name.trimmingCharacters(in: .whitespaces)
        if kind == .manual && title.isEmpty { return false }
        if kind.needsKey && key.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Источник", selection: $kind) {
                    ForEach(SubscriptionKind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Название", text: $name, prompt: Text(defaultName.isEmpty ? "Например, ChatGPT Plus" : defaultName))
                if kind.needsKey {
                    SecureField("Ключ администратора", text: $key)
                    TextField("Лимит в месяц, $", text: $limit, prompt: Text("необязательно"))
                    Text("Ключ сохраняется в связке ключей macOS и передаётся только самому сервису.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if kind == .claudeCode {
                    Text("Лимиты берутся по входу Claude Code на этом Mac. Сервис этот способ не документирует, он может перестать работать. При первом запросе macOS спросит разрешение на доступ к записи Claude Code в связке ключей.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Дата продления", isOn: $hasRenewal)
                if hasRenewal {
                    DatePicker("Ближайшее продление", selection: $renewal, displayedComponents: [.date])
                    Picker("Период", selection: $period) {
                        ForEach(BillingPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Цена", text: $price, prompt: Text("например, 20 $"))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Отмена", action: close).keyboardShortcut(.cancelAction)
                Button("Добавить") {
                    let title = name.trimmingCharacters(in: .whitespaces)
                    let amount = Double(limit.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
                    app.subs.add(Subscription(
                        name: title.isEmpty ? defaultName : title,
                        kind: kind,
                        price: hasRenewal ? price.trimmingCharacters(in: .whitespaces) : "",
                        renewal: hasRenewal ? renewal : nil,
                        period: period,
                        monthlyLimit: kind.needsKey ? amount : nil
                    ), key: key.trimmingCharacters(in: .whitespacesAndNewlines))
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(12)
        }
        .frame(width: 440, height: 430)
    }
}
