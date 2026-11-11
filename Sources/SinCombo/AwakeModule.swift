import SwiftUI
import IOKit
import IOKit.pwr_mgt
import SinComboCore

enum AwakeDuration: Int, CaseIterable, Identifiable {
    case forever = 0
    case minutes30 = 1800
    case hour1 = 3600
    case hours2 = 7200
    case hours5 = 18000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forever: return "Пока не выключу"
        case .minutes30: return "30 минут"
        case .hour1: return "1 час"
        case .hours2: return "2 часа"
        case .hours5: return "5 часов"
        }
    }
}

/// Запрет сна по бездействию — тот же механизм, что у системной команды caffeinate.
/// Закрытая крышка и кнопка «Сон» усыпляют Mac как обычно.
@MainActor
@Observable
final class AwakeModel {
    private static let durationKey = "awakeDuration"

    private(set) var active = false
    private(set) var until: Date?
    private(set) var failed = false
    var duration: AwakeDuration {
        didSet {
            UserDefaults.standard.set(duration.rawValue, forKey: Self.durationKey)
            // Смена времени при включённом режиме запускает отсчёт заново.
            if active { until = deadline() }
        }
    }

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var holdsDisplay = true

    init() {
        duration = AwakeDuration(rawValue: UserDefaults.standard.integer(forKey: Self.durationKey)) ?? .forever
    }

    private func deadline() -> Date? {
        duration == .forever ? nil : Date().addingTimeInterval(TimeInterval(duration.rawValue))
    }

    private func acquire(keepDisplay: Bool) -> Bool {
        release()
        let type = keepDisplay ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(255), "SinCombo: не засыпать" as CFString, &id
        )
        guard status == kIOReturnSuccess else { return false }
        assertion = id
        holdsDisplay = keepDisplay
        return true
    }

    private func release() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    func set(_ on: Bool, keepDisplay: Bool) {
        if on {
            let ok = acquire(keepDisplay: keepDisplay)
            failed = !ok
            active = ok
            until = ok ? deadline() : nil
        } else {
            release()
            active = false
            until = nil
            failed = false
        }
    }

    /// Раз в секунду: выключение по времени и смена режима «Не гасить экран» на ходу.
    func tick(keepDisplay: Bool) {
        guard active else { return }
        if let until, Date() >= until {
            set(false, keepDisplay: keepDisplay)
        } else if holdsDisplay != keepDisplay {
            if !acquire(keepDisplay: keepDisplay) { set(false, keepDisplay: keepDisplay) }
        }
    }

    var remaining: String? {
        guard let until else { return nil }
        let seconds = Int(until.timeIntervalSinceNow)
        return seconds < 60 ? "меньше минуты" : DurationFormat.short(seconds)
    }
}

struct AwakeModuleView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var model = app.awake
        let keepDisplay = app.prefs.isOn(.awakeDisplay)
        ModuleSection(id: .awake) {
            Toggle("Не засыпать", isOn: Binding(
                get: { model.active }, set: { model.set($0, keepDisplay: keepDisplay) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        } content: {
            Picker("Время", selection: $model.duration) {
                ForEach(AwakeDuration.allCases) { Text($0.title).tag($0) }
            }
            .controlSize(.small)
            .padding(.horizontal, 6)
            if model.active {
                // Обращение к счётчику минут заставляет строку обновляться.
                let _ = app.minute
                InfoRow("Состояние", keepDisplay ? "Mac и экран не засыпают" : "Mac не засыпает, экран гаснет")
                if let left = model.remaining { InfoRow("Осталось", left) }
            }
            if model.failed {
                Text("Система не приняла запрет сна.").font(.caption).foregroundStyle(.red).padding(.horizontal, 6)
            }
        }
    }
}
