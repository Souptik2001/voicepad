#if os(macOS)
import AppKit
import Carbon
import VoicepadCore

extension ShortcutMode {
    var title: String {
        switch self {
        case .controlOptionSpace: return "Hold Control–Option–Space"
        case .controlShiftSpace: return "Hold Control–Shift–Space"
        case .doubleCommand: return "Double-tap Command (toggle)"
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .doubleCommand: return 0
        }
    }
}

@MainActor
final class ShortcutController {
    typealias Preset = ShortcutMode

    enum RegistrationError: LocalizedError {
        case failed(OSStatus), inputMonitoring, eventTap
        var errorDescription: String? {
            switch self {
            case .failed(let code):
                return "Shortcut registration failed (\(code)). Another app or macOS may own it. Choose another preset or record from the menu."
            case .inputMonitoring:
                return "Double-Command is not armed. Choose Enable Double-Command Detection… to allow Input Monitoring, or choose a hold shortcut. Menu recording and Copy still work."
            case .eventTap:
                return "Double-Command is not armed: macOS could not install its listener. Retry Enable Double-Command Detection… or choose a hold shortcut."
            }
        }
    }

    private enum Input: Sendable {
        case gesture(CommandDoubleTapDetector.Event, Double)
        case disabled
    }
    private let signature: OSType = 0x56504144 // VPAD
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var detector = CommandDoubleTapDetector()
    private var serial: UInt32 = 0
    private var generation: UInt64 = 0
    private var held = false
    private var suspended = false
    private(set) var preset: Preset?
    private(set) var isArmed = false
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    var onToggle: (() -> Void)?
    var onReset: ((String) -> Void)?

    static var inputMonitoringAllowed: Bool { CGPreflightListenEventAccess() }

    /// Migration is one-time: the old first-launch value 0 was written even when
    /// not explicitly chosen. Preserve alternative 1 and all choices after v1.
    static func initialPreset(defaults: UserDefaults = .standard) -> Preset {
        let saved = defaults.object(forKey: "shortcutPreset") as? Int
        let version = defaults.integer(forKey: "shortcutModeVersion")
        let chosen = Preset.initial(saved: saved, version: version)
        defaults.set(chosen.rawValue, forKey: "shortcutPreset")
        defaults.set(1, forKey: "shortcutModeVersion")
        return chosen
    }

    func register(_ requested: Preset) throws {
        removeRegistration()
        suspended = false
        preset = requested // Keep the chosen mode visible even when unavailable.
        if requested == .doubleCommand {
            // Preflight only: launching or changing mode never prompts.
            guard Self.inputMonitoringAllowed else { throw RegistrationError.inputMonitoring }
            try installTap()
            return
        }
        try installCarbon(requested)
    }

    private func installCarbon(_ requested: Preset) throws {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = types.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr else { return result }
                let owner = Unmanaged<ShortcutController>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                let time = GetEventTime(event)
                let hotKeyID = identifier
                // Both sources are installed only on the main application run loop.
                // Snapshot identity NOW, not when the asynchronous task executes.
                let token = MainActor.assumeIsolated { owner.generation }
                Task { @MainActor [weak owner] in
                    owner?.received(hotKeyID, kind: kind, time: time, generation: token)
                }
                return noErr
            }, buffer.count, buffer.baseAddress, pointer, &handler)
        }
        guard status == noErr else { throw RegistrationError.failed(status) }
        serial &+= 1
        var registration: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: serial)
        let result = RegisterEventHotKey(UInt32(kVK_Space), requested.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &registration)
        guard result == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw RegistrationError.failed(result)
        }
        hotKey = registration
        isArmed = true
    }

    private func installTap() throws {
        let types: [CGEventType] = [.flagsChanged, .keyDown,
                                   .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                   .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let listener = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .listenOnly, eventsOfInterest: mask,
                                               callback: { _, type, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ShortcutController>.fromOpaque(userData).takeUnretainedValue()
            let input = ShortcutController.snapshot(type: type, event: event)
            let token = MainActor.assumeIsolated {
                // Invalidate already-queued gestures before returning to the loop.
                if case .disabled = input { owner.resetInput() }
                return owner.generation
            }
            Task { @MainActor [weak owner] in owner?.received(input, generation: token) }
            // Listen-only: never suppress or modify Command+C or any other input.
            return Unmanaged.passUnretained(event)
        }, userInfo: pointer) else { throw RegistrationError.eventTap }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, listener, 0) else {
            CFMachPortInvalidate(listener)
            throw RegistrationError.eventTap
        }
        tap = listener
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: listener, enable: true)
        isArmed = CGEvent.tapIsEnabled(tap: listener)
        guard isArmed else {
            removeRegistration()
            throw RegistrationError.eventTap
        }
        // Permission revocation need not deliver an event-tap-disabled callback.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    nonisolated private static func snapshot(type: CGEventType, event: CGEvent) -> Input {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return .disabled }
        let time = Double(event.timestamp) / 1_000_000_000
        guard type == .flagsChanged else { return .gesture(.interruption, time) }
        let flags = event.flags
        var modifiers: CommandDoubleTapDetector.Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlphaShift) { modifiers.insert(.capsLock) }
        let other: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
                                   .maskNumericPad, .maskHelp]
        if !flags.intersection(other).isEmpty { modifiers.insert(.other) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if key == 55 || key == 54 {
            // Device-dependent bits distinguish a physical key release while the
            // opposite Command key remains down (aggregate .maskCommand cannot).
            let bit: UInt64 = key == 55 ? 0x8 : 0x10
            return .gesture(.command(key == 55 ? .left : .right,
                                     down: flags.rawValue & bit != 0, modifiers: modifiers), time)
        }
        if key == 57 { return .gesture(.modifiers(modifiers), time) } // Caps Lock only.
        return .gesture(.interruption, time) // All other modifier transitions.
    }

    private func received(_ input: Input, generation token: UInt64) {
        guard token == generation, !suspended, preset == .doubleCommand, tap != nil else { return }
        guard Self.inputMonitoringAllowed else { permissionLost(); return }
        switch input {
        case .disabled:
            resetInput()
            onReset?("Double-Command listener was interrupted. Recording cancelled; gesture reset.")
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                isArmed = CGEvent.tapIsEnabled(tap: tap)
            }
            if !isArmed { permissionLost() }
        case let .gesture(event, time):
            // Reject queued events older than a reset, and unexpectedly delayed
            // delivery rather than letting an old completed gesture start audio.
            let now = ProcessInfo.processInfo.systemUptime
            guard time >= resetTime, time <= now + 0.01, now - time <= 0.5 else {
                detector.reset()
                return
            }
            if detector.receive(event, at: time) { onToggle?() }
        }
    }

    private func received(_ identifier: EventHotKeyID, kind: UInt32, time: Double, generation token: UInt64) {
        guard token == generation, !suspended, isArmed, time >= resetTime,
              identifier.signature == signature, identifier.id == serial, hotKey != nil else { return }
        if kind == UInt32(kEventHotKeyPressed), !held {
            held = true
            onPressed?()
        } else if kind == UInt32(kEventHotKeyReleased), held {
            held = false
            onReleased?()
        }
    }

    // Selection interrupts a partial toggle gesture but must not lose a held
    // Carbon shortcut: its release still needs to stop the microphone.
    func interruptGesture() {
        generation &+= 1
        detector.reset()
        resetTime = ProcessInfo.processInfo.systemUptime
    }

    private var resetTime = ProcessInfo.processInfo.systemUptime
    func resetInput() {
        generation &+= 1
        detector.reset()
        held = false
        resetTime = ProcessInfo.processInfo.systemUptime
    }

    func suspend() {
        suspended = true
        removeRegistration()
    }

    func resume() throws {
        guard suspended, let preset else { return }
        try register(preset)
    }

    func checkHealth() {
        guard preset == .doubleCommand, tap != nil, !suspended else { return }
        guard Self.inputMonitoringAllowed else { permissionLost(); return }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            received(.disabled, generation: generation)
        }
    }

    private func permissionLost() {
        removeRegistration()
        onReset?(RegistrationError.inputMonitoring.localizedDescription)
    }

    private func removeRegistration() {
        resetInput()
        healthTimer?.invalidate()
        healthTimer = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        isArmed = false
    }

    func shutdown() {
        removeRegistration()
        preset = nil
        suspended = true
    }
}
#endif
