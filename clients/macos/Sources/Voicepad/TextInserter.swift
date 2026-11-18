#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import VoicepadCore

@MainActor
enum TextInserter {
    struct Target {
        let application: NSRunningApplication
        let element: AXUIElement
    }
    struct Capture {
        let target: Target?
        let failureReason: String?
    }

    private static let coordinator = PasteCoordinator()
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Capture only on hotkey down, before any Voicepad window can take focus.
    /// No AXSelectedText writability requirement: Chrome/Electron commonly reject
    /// direct AX writes but accept the ordinary Edit > Paste keyboard shortcut.
    static func captureTarget() -> Capture {
        guard isTrusted else { return Capture(target: nil, failureReason: permissionReason) }
        guard !IsSecureEventInputEnabled() else {
            return Capture(target: nil, failureReason: secureReason)
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated,
              let element = focusedElement(in: application.processIdentifier) else {
            return Capture(target: nil, failureReason: "No focused editable field was captured. Use Copy Last Transcript.")
        }
        if let reason = safetyFailure(element) { return Capture(target: nil, failureReason: reason) }
        return Capture(target: Target(application: application, element: element), failureReason: nil)
    }

    static func insert(_ text: String, into target: Target?, failureReason: String?,
                       isCurrent: () -> Bool) async -> PasteResult {
        guard isTrusted else { return PasteResult(message: permissionReason) }
        guard let target else {
            return PasteResult(message: failureReason ?? "No original focused editable field. Paste not requested; use Copy Last Transcript.")
        }
        return await coordinator.insert(text, using: NativePasteEnvironment(target: target), isCurrent: isCurrent)
    }

    static func cancel() { coordinator.cancel() }

    private static let permissionReason = "Accessibility permission is required for automatic paste. Enable Voicepad in System Settings → Privacy & Security → Accessibility. Recording and Copy still work."
    private static let secureReason = "Secure Event Input is enabled. Paste not requested; use Copy Last Transcript only in a safe field."

    private static func focusedElement(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let value = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func selection(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func safetyFailure(_ element: AXUIElement) -> String? {
        let value = attribute(kAXValueAttribute, of: element) as? String
        let range = selection(of: element)
        // A generic web area is not enough. Require an explicit editable flag,
        // or a readable string and real selected-text/range evidence. A page's
        // AXSelectedText alone could just be a selection in read-only content.
        var valueSettable = DarwinBoolean(false)
        let writableValue = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString,
                                                          &valueSettable) == .success && valueSettable.boolValue
        let evidence = writableValue && value != nil && range != nil
            && attribute(kAXSelectedTextAttribute, of: element) is String
        return PasteTargetPolicy.failure(
            role: attribute(kAXRoleAttribute, of: element) as? String,
            subrole: attribute(kAXSubroleAttribute, of: element) as? String ?? "",
            protected: (attribute("AXProtectedContent", of: element) as? NSNumber)?.boolValue == true,
            enabled: (attribute(kAXEnabledAttribute, of: element) as? NSNumber)?.boolValue,
            editable: (attribute("AXEditable", of: element) as? NSNumber)?.boolValue,
            selectionEvidence: evidence)
    }

    @MainActor
    private final class NativePasteEnvironment: PasteEnvironment {
        let target: Target
        let clipboard = NSPasteboard.general
        private var saved: PasteboardSnapshot?
        private var transcriptOwnership: Int?
        init(target: Target) { self.target = target }

        var clipboardChangeCount: Int { clipboard.changeCount }
        var modifiersReleased: Bool {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let keys: [CGKeyCode] = [54, 55, 56, 60, 58, 61, 59, 62]
            return flags.intersection(modifiers).isEmpty
                && !keys.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
        }

        func validationFailure() -> String? {
            guard TextInserter.isTrusted else { return TextInserter.permissionReason }
            guard !IsSecureEventInputEnabled() else { return TextInserter.secureReason }
            guard !target.application.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier,
                  let focused = TextInserter.focusedElement(in: target.application.processIdentifier),
                  CFEqual(focused, target.element) else {
                return "Original app or focused field changed. Paste not requested; use Copy Last Transcript."
            }
            return TextInserter.safetyFailure(focused)
        }

        func snapshotClipboard() throws -> PasteboardSnapshot {
            let count = clipboard.changeCount
            let items = clipboard.pasteboardItems ?? []
            // Do not silently mistake an unreadable, non-empty pasteboard for an
            // empty one. Every advertised representation must materialize.
            guard !items.isEmpty || (clipboard.types ?? []).isEmpty else {
                throw PasteFailure("Clipboard snapshot unavailable. Paste not requested; use Copy Last Transcript.")
            }
            let snapshot = try PasteboardSnapshot.capture(changeCount: count,
                types: items.map { $0.types.map(\.rawValue) },
                read: { items[$0].data(forType: NSPasteboard.PasteboardType($1)) },
                currentChangeCount: { self.clipboard.changeCount })
            saved = snapshot
            return snapshot
        }

        func writeTranscript(_ text: String, replacing changeCount: Int) throws -> Int {
            guard clipboard.changeCount == changeCount else {
                throw PasteFailure("Clipboard changed before paste. Paste not requested; use Copy Last Transcript.")
            }
            // Declaring the concrete type claims ownership and returns its
            // exact token. Setting its data does not declare another owner.
            // NSPasteboard has no cross-process compare-and-swap; minimize the
            // guarded mutation window, and never adopt a later owner's token.
            let claimed = clipboard.declareTypes([.string], owner: nil)
            guard clipboard.changeCount == claimed else {
                throw PasteFailure("Clipboard ownership changed. Paste not requested; use Copy Last Transcript.")
            }
            guard clipboard.setString(text, forType: .string) else {
                if let saved { _ = restoreClipboard(saved, ifOwned: claimed) }
                throw PasteFailure("Clipboard write failed. Paste not requested; use Copy Last Transcript.")
            }
            guard clipboard.changeCount == claimed else {
                throw PasteFailure("Clipboard ownership changed. Paste not requested; use Copy Last Transcript.")
            }
            transcriptOwnership = claimed
            return claimed
        }

        func restoreClipboard(_ snapshot: PasteboardSnapshot, ifOwned changeCount: Int) -> Bool {
            // Build and validate every item BEFORE clearing anything.
            var items: [NSPasteboardItem] = []
            for representations in snapshot.items {
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else { return false }
                }
                items.append(item)
            }
            guard clipboard.changeCount == changeCount else { return false }
            let cleared = clipboard.clearContents()
            guard clipboard.changeCount == cleared else { return false }
            return items.isEmpty || clipboard.writeObjects(items)
        }

        func observeText() -> PasteTextState? {
            let raw = TextInserter.attribute(kAXValueAttribute, of: target.element)
            var value = (raw as? String) ?? (raw as? NSAttributedString)?.string
            // Some contenteditable editors omit AXValue but expose their text
            // through the standard parameterized accessibility text API.
            if value == nil,
               let count = TextInserter.attribute(kAXNumberOfCharactersAttribute, of: target.element) as? NSNumber,
               count.intValue >= 0, count.intValue <= 1_000_000 {
                var range = CFRange(location: 0, length: count.intValue)
                if let parameter = AXValueCreate(.cfRange, &range) {
                    var result: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(target.element,
                        kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success {
                        value = (result as? String) ?? (result as? NSAttributedString)?.string
                    }
                }
            }
            return PasteTextState(value: value, selection: TextInserter.selection(of: target.element))
        }

        func dispatchPaste() -> Bool {
            // Prepare both events before sending either. PID-directed posting
            // avoids a global event going into a different app if focus races.
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
                  validationFailure() == nil, modifiersReleased else { return false }
            // Re-read identity immediately before posting; never activate or
            // set AX focus. No Return/Enter event, submission, or retry.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier,
                  let final = TextInserter.focusedElement(in: target.application.processIdentifier),
                  CFEqual(final, target.element), modifiersReleased,
                  !IsSecureEventInputEnabled(), TextInserter.isTrusted,
                  transcriptOwnership == clipboard.changeCount else { return false }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(target.application.processIdentifier)
            up.postToPid(target.application.processIdentifier)
            return true
        }

        func wait(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
    }
}
#endif
