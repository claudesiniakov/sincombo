import SwiftUI
import SinComboCore

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Выпадающая панель: включённые модули в порядке из настроек и нижняя строка.
struct PanelView: View {
    @Environment(AppState.self) private var app
    @State private var contentHeight: CGFloat = 420

    private var maxHeight: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 24)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                ForEach(app.prefs.layout.visible) { id in
                    module(id)
                }
                footer
            }
            .padding(8)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .frame(width: 320, height: min(max(contentHeight, 60), maxHeight))
        .onAppear { app.panelOpen = true }
        .onDisappear { app.panelOpen = false }
    }

    @ViewBuilder private func module(_ id: ModuleID) -> some View {
        switch id {
        case .calendar: CalendarModuleView()
        case .sound: SoundModuleView()
        case .wifi: WiFiModuleView()
        case .bluetooth: BluetoothModuleView()
        case .vpn: VPNModuleView()
        case .battery: BatteryModuleView()
        case .subs: SubsModuleView()
        case .awake: AwakeModuleView()
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if app.updater.needsAttention {
                HStack(spacing: 8) {
                    Text(app.updater.statusLine)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(app.updater.isFailed ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(app.updater.failureDetails ?? "")
                    Spacer(minLength: 0)
                    if let action = app.updater.actionTitle {
                        Button(action) { app.updater.primaryAction() }.buttonStyle(.link).font(.callout)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { SettingsWindow.show(tab: .modules) } label: {
                    Label("Настройки…", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text("SinCombo \(app.updater.currentVersionString)").font(.caption).foregroundStyle(.secondary)
                Button("Завершить") { app.quit() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

// MARK: - Общие элементы модулей

/// Блок модуля: заголовок со сворачиванием и содержимое.
struct ModuleSection<Accessory: View, Content: View>: View {
    @Environment(AppState.self) private var app
    let id: ModuleID
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        let collapsed = app.prefs.collapsed.contains(id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { app.prefs.toggleCollapsed(id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: id.symbol).frame(width: 18)
                        Text(id.title).fontWeight(.semibold)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(id.title + (collapsed ? ", свёрнуто" : ""))
                accessory()
            }
            if !collapsed {
                content()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

/// Строка-кнопка с подсветкой при наведении.
struct RowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) { content() }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct IconDot: View {
    let symbol: String
    let active: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(active ? Color.accentColor : Color.primary.opacity(0.1)))
    }
}

struct LinkRow: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.callout)
            .padding(.horizontal, 6)
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }
}

struct SubTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 2)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.horizontal, 6)
    }
}

/// Полоса заполнения: заряд, расход лимита, оплаченный период.
struct Meter: View {
    let fraction: Double
    let warn: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(warn ? Color.red : Color.green)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: 7)
        .padding(.horizontal, 6)
    }
}
