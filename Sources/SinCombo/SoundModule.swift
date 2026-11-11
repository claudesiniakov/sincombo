import SwiftUI
import CoreAudio
import SinComboCore

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return hasOutput ? "laptopcomputer" : "mic"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return hasOutput ? "hifispeaker" : "mic"
        default: return hasOutput ? "speaker.wave.2" : "mic"
        }
    }
}

/// Тонкая обёртка над свойствами CoreAudio.
enum Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Громкость устройства целиком ('vmvc'), а не отдельных каналов.
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func settable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var flag: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &flag) == noErr && flag.boolValue
    }

    static func size(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32 {
        var address = address
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr ? size : 0
    }

    static func name(_ device: AudioDeviceID) -> String {
        var addr = Audio.address(kAudioObjectPropertyName)
        var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var reference: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &length, &reference)
        guard status == noErr, let reference else { return "" }
        return reference.takeRetainedValue() as String
    }

    static func devices() -> [AudioDevice] {
        var addr = Audio.address(kAudioHardwarePropertyDevices)
        var length = Audio.size(system, addr)
        let count = Int(length) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &length, &ids) == noErr else { return [] }
        return ids.prefix(Int(length) / MemoryLayout<AudioDeviceID>.size).compactMap { id -> AudioDevice? in
            let output = Audio.size(id, Audio.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)) > 0
            let input = Audio.size(id, Audio.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)) > 0
            guard output || input else { return nil }
            let transport: UInt32 = Audio.get(id, Audio.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
            // Составные и виртуальные устройства системы в списке не нужны.
            if transport == kAudioDeviceTransportTypeAggregate { return nil }
            let title = Audio.name(id)
            guard !title.isEmpty else { return nil }
            return AudioDevice(id: id, name: title, hasOutput: output, hasInput: input, transport: transport)
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let id: AudioDeviceID? = Audio.get(system, Audio.address(selector), initial: AudioDeviceID(0))
        return id == 0 ? nil : id
    }

    static func volume(_ device: AudioDeviceID, input: Bool) -> Float? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let addr = Audio.address(virtualMainVolume, scope)
        guard has(device, addr), settable(device, addr) else { return nil }
        let value: Float32? = Audio.get(device, addr, initial: Float32(0))
        return value
    }

    static func muted(_ device: AudioDeviceID, input: Bool) -> Bool {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let value: UInt32? = Audio.get(device, Audio.address(kAudioDevicePropertyMute, scope), initial: UInt32(0))
        return value == 1
    }
}

@MainActor
@Observable
final class SoundModel {
    private(set) var devices: [AudioDevice] = []
    private(set) var output: AudioDeviceID?
    private(set) var input: AudioDeviceID?
    /// `nil` — у устройства нет программной громкости (мониторы по HDMI и DisplayPort).
    private(set) var volume: Float?
    private(set) var muted = false
    private(set) var inputVolume: Float?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var watched: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var systemBlock: AudioObjectPropertyListenerBlock?

    var outputs: [AudioDevice] { devices.filter(\.hasOutput) }
    var inputs: [AudioDevice] { devices.filter(\.hasInput) }

    func start() {
        guard !started else { return }
        started = true
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in AppState.shared.sound.reload() }
        }
        systemBlock = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var address = Audio.address(selector)
            AudioObjectAddPropertyListenerBlock(Audio.system, &address, DispatchQueue.main, block)
        }
        reload()
    }

    func reload() {
        let list = Audio.devices()
        if devices != list { devices = list }
        let out = Audio.defaultDevice(input: false)
        let inp = Audio.defaultDevice(input: true)
        if output != out || input != inp {
            output = out
            input = inp
            rewatch()
        }
        readLevels()
    }

    private func readLevels() {
        let v = output.flatMap { Audio.volume($0, input: false) }
        if volume != v { volume = v }
        let m = output.map { Audio.muted($0, input: false) } ?? false
        if muted != m { muted = m }
        let iv = input.flatMap { Audio.volume($0, input: true) }
        if inputVolume != iv { inputVolume = iv }
    }

    /// Следим за громкостью и отключением звука только у текущих устройств.
    private func rewatch() {
        for (device, address, block) in watched {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        watched = []
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in AppState.shared.sound.readLevelsFromListener() }
        }
        var targets: [(AudioDeviceID, AudioObjectPropertyAddress)] = []
        if let output {
            targets.append((output, Audio.address(Audio.virtualMainVolume, kAudioObjectPropertyScopeOutput)))
            targets.append((output, Audio.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)))
        }
        if let input {
            targets.append((input, Audio.address(Audio.virtualMainVolume, kAudioObjectPropertyScopeInput)))
        }
        for (device, address) in targets where Audio.has(device, address) {
            var mutable = address
            if AudioObjectAddPropertyListenerBlock(device, &mutable, DispatchQueue.main, block) == noErr {
                watched.append((device, address, block))
            }
        }
    }

    func readLevelsFromListener() { readLevels() }

    func setVolume(_ value: Float) {
        guard let output else { return }
        let clamped = min(1, max(0, value))
        Audio.set(output, Audio.address(Audio.virtualMainVolume, kAudioObjectPropertyScopeOutput), Float32(clamped))
        if muted, clamped > 0 { setMuted(false) }
        volume = clamped
    }

    func setMuted(_ value: Bool) {
        guard let output else { return }
        Audio.set(output, Audio.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(value ? 1 : 0))
        muted = value
    }

    func setInputVolume(_ value: Float) {
        guard let input else { return }
        let clamped = min(1, max(0, value))
        Audio.set(input, Audio.address(Audio.virtualMainVolume, kAudioObjectPropertyScopeInput), Float32(clamped))
        inputVolume = clamped
    }

    func select(_ device: AudioDevice, input asInput: Bool) {
        let selector = asInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        Audio.set(Audio.system, Audio.address(selector), device.id)
        reload()
    }
}

struct SoundModuleView: View {
    @Environment(AppState.self) private var app

    private var model: SoundModel { app.sound }
    private var prefs: Prefs { app.prefs }

    var body: some View {
        ModuleSection(id: .sound) {
            EmptyView()
        } content: {
            HStack(spacing: 8) {
                Button { model.setMuted(!model.muted) } label: {
                    Image(systemName: speakerSymbol)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                        .foregroundStyle(model.muted ? Color.red : Color.primary)
                }
                .buttonStyle(.plain)
                .help(model.muted ? "Включить звук" : "Выключить звук")
                .accessibilityLabel(model.muted ? "Включить звук" : "Выключить звук")
                Slider(
                    value: Binding(get: { Double(model.volume ?? 0) }, set: { model.setVolume(Float($0)) }),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(model.volume == nil)
                .accessibilityLabel("Громкость")
                Text(model.volume.map { "\(Int(($0 * 100).rounded())) %" } ?? "—")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            if model.volume == nil, model.output != nil {
                Hint("Громкость этого устройства регулируется на нём самом.")
            }
            if prefs.isOn(.soundOutputs) {
                SubTitle("Вывод")
                ForEach(model.outputs) { device in
                    RowButton(action: { model.select(device, input: false) }) {
                        IconDot(symbol: device.symbol, active: device.id == model.output)
                        Text(device.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if device.id == model.output { Image(systemName: "checkmark").font(.caption) }
                    }
                }
            }
            if prefs.isOn(.soundInput) {
                SubTitle("Ввод")
                ForEach(model.inputs) { device in
                    RowButton(action: { model.select(device, input: true) }) {
                        IconDot(symbol: "mic", active: device.id == model.input)
                        Text(device.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if device.id == model.input { Image(systemName: "checkmark").font(.caption) }
                    }
                }
                if let level = model.inputVolume {
                    HStack(spacing: 8) {
                        Image(systemName: "mic").frame(width: 26, height: 26)
                        Slider(
                            value: Binding(get: { Double(level) }, set: { model.setInputVolume(Float($0)) }),
                            in: 0...1
                        )
                        .controlSize(.small)
                        .accessibilityLabel("Уровень микрофона")
                        Text("\(Int((level * 100).rounded())) %")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
            if prefs.isOn(.soundSettings) {
                LinkRow("Настройки звука…") { SystemSettings.sound.open() }
            }
        }
    }

    private var speakerSymbol: String {
        if model.muted || (model.volume ?? 1) == 0 { return "speaker.slash.fill" }
        let v = model.volume ?? 1
        return v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}
