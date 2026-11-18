#if os(macOS)
import AppKit
import VoicepadCore

/// A separate short-lived active tap, never the listen-only Command detector.
/// No permission prompt: without suppression permission, HUD clicks still work.
@MainActor
final class ProfileKeyController {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var presses = ProfileKeyPresses()
    var onKey: ((Int, Bool) -> Bool)?
    var onUnavailable: (() -> Void)?

    @discardableResult
    func start() -> Bool {
        stop()
        guard CGPreflightPostEventAccess() else { return false }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ProfileKeyController>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.stop()
                    owner.onUnavailable?()
                    return Unmanaged.passUnretained(event)
                }
                let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
                let modified = !event.flags.intersection(modifiers).isEmpty
                let handle = owner.onKey
                let handled = owner.presses.consume(key: key, down: type == .keyDown) {
                    handle?(key, modified) == true
                }
                return handled ? nil : Unmanaged.passUnretained(event)
            }
        }, userInfo: pointer) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { stop(); return false }
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        presses.reset()
    }
}
#endif
