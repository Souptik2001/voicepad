#if os(macOS)
import AppKit
import AVFoundation

private enum VoicepadPanelPalette {
    static let paper = NSColor(srgbRed: 245/255, green: 242/255, blue: 233/255, alpha: 1)
    static let ivory = NSColor(srgbRed: 252/255, green: 250/255, blue: 245/255, alpha: 1)
    static let ink = NSColor(srgbRed: 48/255, green: 46/255, blue: 41/255, alpha: 1)
    static let muted = NSColor(srgbRed: 112/255, green: 108/255, blue: 98/255, alpha: 1)
    static let terracotta = NSColor(srgbRed: 169/255, green: 79/255, blue: 53/255, alpha: 1)
    static let line = NSColor(srgbRed: 222/255, green: 217/255, blue: 205/255, alpha: 1)
}

@MainActor
final class TranscriptPanel: NSObject {
    private let panel: NSPanel
    private let textView = NSTextView()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    var onCopy: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 350),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Voicepad Transcript"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 360, height: 240)
        panel.center()
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = VoicepadPanelPalette.ivory.cgColor
            content.layer?.cornerRadius = 16
            content.layer?.borderWidth = 1
            content.layer?.borderColor = VoicepadPanelPalette.line.cgColor
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = VoicepadPanelPalette.ink
        textView.backgroundColor = VoicepadPanelPalette.paper
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Transcribed text")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.backgroundColor = VoicepadPanelPalette.paper
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderColor = VoicepadPanelPalette.line.cgColor
        scroll.layer?.borderWidth = 1
        scroll.documentView = textView
        let copy = NSButton(title: "  Copy  ", target: self, action: #selector(copyText))
        copy.setAccessibilityLabel("Copy transcript to clipboard")
        copy.isBordered = false
        copy.bezelStyle = .rounded
        copy.font = .systemFont(ofSize: 13, weight: .semibold)
        copy.contentTintColor = VoicepadPanelPalette.ivory
        copy.wantsLayer = true
        copy.layer?.backgroundColor = VoicepadPanelPalette.terracotta.cgColor
        copy.layer?.cornerRadius = 8
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = VoicepadPanelPalette.muted
        explanation.maximumNumberOfLines = 3
        let stack = NSStackView(views: [explanation, scroll, copy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
                copy.widthAnchor.constraint(equalToConstant: 92),
                copy.heightAnchor.constraint(equalToConstant: 32),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
            ])
        }
    }

    func setTranscript(_ text: String, message: String, show: Bool) {
        textView.string = text
        explanation.stringValue = message
        if show { panel.orderFrontRegardless() } // Blocked paste: visible recovery, without activation.
        else { panel.orderOut(nil) } // Do not leave an earlier recovery window over typing.
    }

    func showExplicitly() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func clear() { textView.string = ""; panel.orderOut(nil) }
    @objc private func copyText() { onCopy?() }
}

@MainActor
enum PermissionPresentation {
    /// Only this explicit menu action may request Input Monitoring.
    static func enableDoubleCommand() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Enable Double-Command Detection"
        alert.informativeText = "Tap either Command key twice to start recording; repeat to stop and transcribe. Use the same physical key for both taps, with no other keys or mouse clicks. Each tap must be released within 0.3 seconds; the gap may be up to 0.35 seconds.\n\nThis requires Input Monitoring to observe modifier changes and reject mixed gestures. Voicepad does not log typing or suppress normal shortcuts. While listening, profile keys 0–9 are consumed only when handled and Accessibility permits suppression; click the nonactivating profile chips otherwise. Accessibility is separately required for automatic paste: Voicepad temporarily puts the transcript on the clipboard and requests standard Command-V in the original focused field, without submitting it. Release all modifier keys before paste.\n\nEnable Voicepad in System Settings → Privacy & Security → Input Monitoring. macOS may require quitting and reopening Voicepad. Then choose this menu item again to retry. Hold shortcuts and menu recording work without Input Monitoring."
        alert.addButton(withTitle: "Enable / Retry")
        alert.addButton(withTitle: "Open Input Monitoring Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !CGPreflightListenEventAccess() {
                _ = CGRequestListenEventAccess()
                if !CGPreflightListenEventAccess() { openPrivacy("Privacy_ListenEvent") }
            }
            return true
        case .alertSecondButtonReturn:
            openPrivacy("Privacy_ListenEvent")
            return true
        default: return false
        }
    }

    static func show() {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "Allowed"
        case .denied: microphone = "Denied"
        case .restricted: microphone = "Restricted by your administrator"
        case .notDetermined: microphone = "Not requested — start a recording to request access"
        @unknown default: microphone = "Unknown"
        }
        let alert = NSAlert()
        alert.messageText = "Voicepad Permissions"
        alert.informativeText = "Microphone (required): \(microphone).\n\nAccessibility (required for automatic paste and global profile number keys): \(TextInserter.isTrusted ? "Allowed" : "Not allowed"). Voicepad requests standard Command-V only when the original app and editable field remain focused. It never activates that app, presses Return or submits text. Protected fields are excluded. Recording and Copy work without Accessibility; menu recordings use Copy.\n\nClipboard: automatic paste temporarily replaces the clipboard with the transcript after saving all available representations in memory (up to 16 MB). It restores the saved clipboard after confirming text arrived, or after a two-second paste window when delivery cannot be read back, only if Voicepad still owns the clipboard. A newer copy is preserved. Recovery text remains in the VP menu. A very slow receiver may need manual recovery. Check the field before pasting again: an unconfirmed request may have arrived. There is no automatic retry.\n\nInput Monitoring (Double-Command only): \(CGPreflightListenEventAccess() ? "Allowed" : "Not allowed"). Use Enable Double-Command Detection… to request access or retry. Hold shortcuts and menu recording do not need it. Voicepad does not log typing or suppress normal shortcuts. While listening, profile keys 0–9 are consumed only when handled and Accessibility permits suppression; click the nonactivating profile chips otherwise. Escape outside Voicepad works only with Accessibility; Cancel is always in the menu and activity panel.\n\nNo OAuth credentials are stored in this app. Keep macOS security protections enabled."
        alert.addButton(withTitle: "Microphone Settings")
        alert.addButton(withTitle: "Accessibility Settings")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openPrivacy("Privacy_Microphone")
        } else if response == .alertSecondButtonReturn {
            openPrivacy("Privacy_Accessibility")
        }
    }

    private static func openPrivacy(_ section: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
