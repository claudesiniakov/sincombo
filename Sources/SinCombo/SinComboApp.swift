import SwiftUI
import AppKit
import SinComboCore

@main
struct SinComboApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(app)
        } label: {
            Image(nsImage: app.menuBarImage)
                .accessibilityLabel("SinCombo")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Второй экземпляр не нужен: в строке меню появился бы второй значок.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil)
            return
        }
        AppState.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.vpn.flush()
    }
}

/// Общее состояние приложения: настройки, модели модулей и секундный цикл.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let prefs = Prefs.shared
    let updater = Updater()
    let wifi = WiFiModel()
    let bluetooth = BluetoothModel()
    let sound = SoundModel()
    let calendar = CalendarModel()
    let battery = BatteryModel()
    let vpn = VPNModel()
    let subs = SubsModel()
    let awake = AwakeModel()

    private(set) var launchAtLogin = LoginItem.isEnabled
    /// Меняется раз в минуту, чтобы текст в строке меню не устаревал.
    private(set) var minute = 0

    var panelOpen = false {
        didSet { if panelOpen != oldValue { panelChanged() } }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var seconds = 0
    @ObservationIgnored private var lastUpdatePoll = Date.distantPast

    func start() {
        guard loop == nil else { return }
        LoginItem.repairIfMoved()
        launchAtLogin = LoginItem.isEnabled
        updater.beforeRestart = { [weak self] in self?.vpn.flush() }
        sound.start()
        battery.start()
        calendar.start()
        if needsCalendarEvents { calendar.activate(wantEvents: false); calendar.reload() }
        loop = Task {
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func enabled(_ id: ModuleID) -> Bool { prefs.layout.isEnabled(id) }

    /// VPN опрашивается, только если модуль включён или его значок выведен в строку меню.
    private var vpnNeeded: Bool { enabled(.vpn) || prefs.barVPN }

    private var needsCalendarEvents: Bool {
        (enabled(.calendar) && prefs.isOn(.calEvents)) || prefs.barText == .nextEvent
    }

    /// Панель реально на экране: есть видимое окно, кроме окна настроек.
    private var panelVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.frame.height > 50 && $0.title != SettingsWindow.title && $0.sheetParent == nil }
    }

    private func panelChanged() {
        vpn.panelOpen = panelOpen && vpnNeeded
        guard panelOpen else { return }
        seconds = 0
        refreshModules(first: true)
    }

    /// Выключенный модуль не опрашивает систему и не запрашивает разрешений.
    private func refreshModules(first: Bool) {
        if enabled(.wifi) {
            if first { wifi.refresh() } else { wifi.readState() }
        }
        if enabled(.bluetooth) { bluetooth.refresh(withBattery: prefs.isOn(.btBattery)) }
        if enabled(.sound) { sound.reload() }
        if enabled(.battery) || prefs.barBattery || prefs.barText == .battery { battery.reload() }
        if first {
            if enabled(.calendar) { calendar.activate(wantEvents: prefs.isOn(.calEvents)) }
            if enabled(.subs) { subs.refreshIfDue() }
        }
    }

    private func tick() async {
        // Признак «панель открыта» сверяется с окнами: событие закрытия может не прийти.
        let visible = panelVisible
        if panelOpen != visible { panelOpen = visible }

        if vpnNeeded {
            vpn.start()
            await vpn.tick()
        }

        awake.tick(keepDisplay: prefs.isOn(.awakeDisplay))

        seconds += 1
        if panelOpen {
            if seconds % 3 == 0 { refreshModules(first: false) }
            // Сканирование сетей — раз в 10 секунд, пока модуль развёрнут.
            if seconds % 10 == 0, enabled(.wifi), !prefs.collapsed.contains(.wifi) { wifi.refresh() }
        }

        let now = Date()
        let currentMinute = Int(now.timeIntervalSince1970 / 60)
        if minute != currentMinute {
            minute = currentMinute
            calendar.dayChanged()
        }
        if now.timeIntervalSince(lastUpdatePoll) >= 3600 {
            lastUpdatePoll = now
            Task { await updater.checkIfDue() }
        }
    }

    // MARK: - Строка меню

    private static let barDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private static let barWeekdayDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private static let barTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeStyle = .short
        return f
    }()

    private var barString: String? {
        _ = minute
        switch prefs.barText {
        case .none:
            return nil
        case .date:
            return Self.barDate.string(from: calendar.today)
        case .weekdayDate:
            return Self.barWeekdayDate.string(from: calendar.today)
        case .nextEvent:
            guard let event = calendar.nextEventToday else { return "Нет событий" }
            let title = event.title.count > 18 ? String(event.title.prefix(17)) + "…" : event.title
            return Self.barTime.string(from: event.start) + " " + title
        case .battery:
            return battery.state.map { "\($0.percent) %" }
        }
    }

    var menuBarImage: NSImage {
        var vpnBadge: MenuBarArt.VPNBadge?
        if prefs.barVPN {
            if vpn.anyConnected {
                vpnBadge = .on
            } else if vpn.transitional {
                vpnBadge = vpn.blink ? .dim : .off
            } else {
                vpnBadge = .off
            }
        }
        var batteryBadge: (Int, Bool)?
        if prefs.barBattery, let state = battery.state { batteryBadge = (state.percent, state.charging) }
        return MenuBarArt.image(
            vpn: vpnBadge, battery: batteryBadge, awake: prefs.barAwake && awake.active, text: barString
        )
    }

    // MARK: - Прочее

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try LoginItem.enable()
            } else {
                try LoginItem.disable()
            }
        } catch {
            NSLog("SinCombo: автозапуск: \(error.localizedDescription)")
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func quit() {
        vpn.flush()
        NSApp.terminate(nil)
    }
}

/// Значок строки меню: шестерёнки, по желанию — значок VPN, значок аккумулятора и текст.
/// Шаблонное изображение: цвет подбирает система.
enum MenuBarArt {
    enum VPNBadge: String { case off, dim, on }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(vpn: VPNBadge?, battery: (Int, Bool)?, awake: Bool, text: String?) -> NSImage {
        let key = "\(awake)|\(vpn?.rawValue ?? "-")|\(battery.map { "\($0.0)\($0.1)" } ?? "-")|\(text ?? "")"
        if let cached = cache[key] { return cached }
        if cache.count > 200 { cache.removeAll() }

        let label = text.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.black,
            ])
        }
        let gap: CGFloat = 5
        let height: CGFloat = 18
        var width: CGFloat = height
        if vpn != nil { width += gap + 28 }
        if battery != nil { width += gap + (battery?.1 == true ? 33 : 26) }
        if awake { width += gap + 17 }
        if let label { width += gap + ceil(label.size().width) }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var x: CGFloat = 0
            drawGears(in: NSRect(x: 0, y: 0, width: height, height: height))
            x += height
            if let vpn {
                x += gap
                drawVPN(vpn, in: NSRect(x: x, y: 1.5, width: 28, height: 15))
                x += 28
            }
            if let battery {
                x += gap
                x += drawBattery(percent: battery.0, charging: battery.1, at: NSPoint(x: x, y: 3.5))
            }
            if awake {
                x += gap
                // Чашка: «Не засыпать» включено.
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                if let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let size = cup.size
                    let scale = min(17 / max(size.width, 1), 14 / max(size.height, 1), 1)
                    let w = size.width * scale, h = size.height * scale
                    cup.draw(
                        in: NSRect(x: x + (17 - w) / 2, y: (height - h) / 2, width: w, height: h),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                    )
                }
                x += 17
            }
            if let label {
                x += gap
                let size = label.size()
                label.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// Шестерёнки отдельной картинкой — для окна настроек.
    static func gears(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            drawGears(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func gear(cx: CGFloat, cy: CGFloat, outer: CGFloat, inner: CGFloat, teeth: Int, hole: CGFloat, rotation: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let step = 2 * CGFloat.pi / CGFloat(teeth)
        let profile: [(CGFloat, CGFloat)] = [(-0.27, inner), (-0.14, outer), (0.14, outer), (0.27, inner)]
        for tooth in 0..<teeth {
            for (index, point) in profile.enumerated() {
                let angle = rotation + (CGFloat(tooth) + point.0) * step
                let p = NSPoint(x: cx + point.1 * cos(angle), y: cy + point.1 * sin(angle))
                if tooth == 0 && index == 0 {
                    path.move(to: p)
                } else {
                    path.line(to: p)
                }
            }
        }
        path.close()
        path.appendOval(in: NSRect(x: cx - hole, y: cy - hole, width: hole * 2, height: hole * 2))
        path.windingRule = .evenOdd
        return path
    }

    /// Три сцепленные шестерёнки; координаты заданы в сетке 24×24.
    private static func drawGears(in rect: NSRect) {
        let k = rect.width / 24
        NSColor.black.setFill()
        let gears: [(CGFloat, CGFloat, CGFloat, CGFloat, Int, CGFloat, CGFloat)] = [
            (9, 14.5, 7.6, 5.7, 9, 2.3, 0),
            (17.6, 6.6, 4.9, 3.5, 7, 1.4, 0.2),
            (19.3, 17.6, 3.7, 2.6, 6, 1.0, 0.5),
        ]
        for g in gears {
            gear(
                cx: rect.minX + g.0 * k, cy: rect.minY + g.1 * k,
                outer: g.2 * k, inner: g.3 * k, teeth: g.4, hole: g.5 * k, rotation: g.6
            ).fill()
        }
    }

    private static func drawVPN(_ badge: VPNBadge, in rect: NSRect) {
        let color = NSColor.black.withAlphaComponent(badge == .dim ? 0.35 : 1)
        let kern: CGFloat = 1.0
        let text = NSAttributedString(string: "VPN", attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .kern: kern,
            .foregroundColor: color,
        ])
        let size = text.size()
        let origin = NSPoint(x: rect.minX + (rect.width - (size.width - kern)) / 2, y: rect.minY + (rect.height - size.height) / 2)
        if badge == .on {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: origin)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            frame.lineWidth = 1
            color.setStroke()
            frame.stroke()
            text.draw(at: origin)
        }
    }

    /// Рисует батарею и возвращает занятую ширину.
    private static func drawBattery(percent: Int, charging: Bool, at origin: NSPoint) -> CGFloat {
        var x = origin.x
        NSColor.black.setFill()
        NSColor.black.setStroke()
        if charging {
            // Молния слева от батареи.
            let bolt = NSBezierPath()
            let y = origin.y
            bolt.move(to: NSPoint(x: x + 4.5, y: y))
            bolt.line(to: NSPoint(x: x + 0.5, y: y + 6.2))
            bolt.line(to: NSPoint(x: x + 3, y: y + 6.2))
            bolt.line(to: NSPoint(x: x + 1.5, y: y + 11))
            bolt.line(to: NSPoint(x: x + 5.5, y: y + 4.6))
            bolt.line(to: NSPoint(x: x + 3, y: y + 4.6))
            bolt.close()
            bolt.fill()
            x += 7
        }
        let body = NSRect(x: x + 0.5, y: origin.y + 0.5, width: 22, height: 10)
        let frame = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
        frame.lineWidth = 1
        frame.stroke()
        NSBezierPath(roundedRect: NSRect(x: x + 23.5, y: origin.y + 3.5, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
        let inner = body.insetBy(dx: 2, dy: 2)
        let level = max(0, min(1, CGFloat(percent) / 100))
        if level > 0 {
            NSBezierPath(
                roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * level), height: inner.height),
                xRadius: 1.2, yRadius: 1.2
            ).fill()
        }
        return (charging ? 7 : 0) + 26
    }
}
