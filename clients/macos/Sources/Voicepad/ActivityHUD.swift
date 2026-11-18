#if os(macOS)
import AppKit
import VoicepadCore

private final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draw within the actual button bounds, not AppKit's intrinsic title-sized frame.
private final class ProfileChipCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let content = ActivityHUDLayout.profileChipContentRect(in: controlView.bounds)
        let height = min(content.height, ceil(title.size().height))
        let centered = NSRect(x: content.minX, y: content.midY - height / 2,
                              width: content.width, height: height)
        return super.drawTitle(title, withFrame: centered, in: controlView)
    }
}

private final class ProfileChipButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private enum VoicepadPalette {
    static let paper = NSColor(srgbRed: 245/255, green: 242/255, blue: 233/255, alpha: 1)
    static let ivory = NSColor(srgbRed: 252/255, green: 250/255, blue: 245/255, alpha: 1)
    static let ink = NSColor(srgbRed: 48/255, green: 46/255, blue: 41/255, alpha: 1)
    static let muted = NSColor(srgbRed: 112/255, green: 108/255, blue: 98/255, alpha: 1)
    static let terracotta = NSColor(srgbRed: 169/255, green: 79/255, blue: 53/255, alpha: 1)
    static let line = NSColor(srgbRed: 222/255, green: 217/255, blue: 205/255, alpha: 1)
}

/// Level-history bars driven by the recorder's real microphone meter.
private final class ActivityGlyph: NSView {
    var recording = false { didSet { needsDisplay = true } }
    var processing = false { didSet { needsDisplay = true } }
    private var waveform = MicrophoneWaveform()
    func update(decibels: Double) {
        waveform.update(decibels: decibels)
        needsDisplay = true
    }
    func reset() { waveform.reset(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        VoicepadPalette.terracotta.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        VoicepadPalette.terracotta.setFill()
        if recording {
            let heights = waveform.heights(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            for (index, value) in heights.enumerated() {
                let height = CGFloat(value)
                let rect = NSRect(x: 10 + CGFloat(index) * 4.5, y: bounds.midY - height/2, width: 2.5, height: height)
                NSBezierPath(roundedRect: rect, xRadius: 1.25, yRadius: 1.25).fill()
            }
        } else if processing {
            for index in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(index)*7, y: bounds.midY-2, width: 4, height: 4)).fill()
            }
        } else {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX-4, y: bounds.midY-4, width: 8, height: 8)).fill()
        }
    }
}

@MainActor
final class ActivityHUD: NSObject {
    private let panel: NSPanel
    private let material = NSVisualEffectView()
    private let tint = NSView()
    private let brand = NSTextField(labelWithString: "VOICEPAD")
    private let heading = NSTextField(labelWithString: "Listening")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let time = NSTextField(labelWithString: "00:00")
    private let glyph = ActivityGlyph(frame: .zero)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private var dismissalTimer: Timer?
    private var presentationGeneration = 0
    private let profileGrid = NSStackView()
    private let profileStatus = NSTextField(labelWithString: "")
    private var displayedChips: [ProfileSelection.Chip] = []
    private var pinnedVisibleFrame: CGRect?
    var onProfile: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    override init() {
        panel = ActivityPanel(contentRect: NSRect(x: 0, y: 0, width: 272, height: 116),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Voicepad Activity"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.appearance = NSAppearance(named: .aqua)
        material.wantsLayer = true
        material.layer?.cornerRadius = 18
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.layer?.borderColor = VoicepadPalette.line.withAlphaComponent(0.8).cgColor
        panel.contentView = material
        tint.wantsLayer = true
        tint.layer?.backgroundColor = VoicepadPalette.paper.withAlphaComponent(0.72).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            tint.topAnchor.constraint(equalTo: material.topAnchor),
            tint.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        brand.font = .systemFont(ofSize: 9, weight: .semibold)
        brand.textColor = VoicepadPalette.terracotta
        heading.font = NSFont(name: "Georgia", size: 20) ?? .systemFont(ofSize: 20, weight: .medium)
        heading.textColor = VoicepadPalette.ink
        heading.lineBreakMode = .byTruncatingTail
        heading.setAccessibilityLabel("Voicepad activity")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = VoicepadPalette.muted
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        time.textColor = VoicepadPalette.muted
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
        cancelButton.imagePosition = .imageOnly
        cancelButton.isBordered = false
        cancelButton.contentTintColor = VoicepadPalette.muted
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.toolTip = "Cancel recording or processing"
        cancelButton.setAccessibilityLabel("Cancel Voicepad recording or processing")
        for view in [brand, heading, detail, time, glyph, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(view)
        }
        profileGrid.orientation = .vertical
        profileGrid.spacing = 4
        profileGrid.alignment = .leading
        profileStatus.font = .systemFont(ofSize: 9, weight: .medium)
        profileStatus.textColor = VoicepadPalette.muted
        for view in [profileGrid, profileStatus] {
            view.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(view)
        }
        NSLayoutConstraint.activate([
            profileStatus.topAnchor.constraint(equalTo: material.topAnchor, constant: 109),
            profileStatus.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            profileStatus.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12),
            profileGrid.topAnchor.constraint(equalTo: material.topAnchor, constant: 128),
            profileGrid.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            profileGrid.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12)
        ])
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            brand.topAnchor.constraint(equalTo: material.topAnchor, constant: 13),
            time.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -7),
            time.centerYAnchor.constraint(equalTo: brand.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            cancelButton.topAnchor.constraint(equalTo: material.topAnchor, constant: 3),
            cancelButton.widthAnchor.constraint(equalToConstant: 28),
            cancelButton.heightAnchor.constraint(equalToConstant: 28),
            glyph.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            glyph.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 13),
            glyph.widthAnchor.constraint(equalToConstant: 42),
            glyph.heightAnchor.constraint(equalToConstant: 42),
            heading.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 11),
            heading.topAnchor.constraint(equalTo: glyph.topAnchor, constant: -1),
            heading.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -14),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4)
        ])
    }

    func show(title: String, detail message: String, canCancel: Bool = true, elapsed: TimeInterval? = nil, microphonePower: Double? = nil, profileSelection: ProfileSelection? = nil, profileKeyboardAvailable: Bool = false) {
        presentationGeneration += 1
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        let content = ActivityHUDContent(title: title, detail: message, elapsed: elapsed)
        heading.stringValue = content.heading
        heading.font = NSFont(name: "Georgia", size: 20) ?? .systemFont(ofSize: 20, weight: .medium)
        detail.stringValue = content.subtitle
        detail.toolTip = message
        time.stringValue = content.time ?? ""
        glyph.recording = content.recording
        glyph.processing = content.processing
        if content.recording { glyph.update(decibels: microphonePower ?? -160) }
        else { glyph.reset() }
        cancelButton.isHidden = !canCancel
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material.state = reduceTransparency ? .inactive : .active
        tint.layer?.backgroundColor = VoicepadPalette.paper.withAlphaComponent(reduceTransparency ? 1 : 0.72).cgColor
        let selection = content.recording ? profileSelection : nil
        updateProfiles(selection, keyboardAvailable: profileKeyboardAvailable)
        if !panel.isVisible {
            // Choose the pointer's display once per recording, then don't chase it.
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
            pinnedVisibleFrame = screen?.visibleFrame
        }
        let rows = selection.map { ($0.chips.count + 2) / 3 } ?? 0
        if let visible = pinnedVisibleFrame {
            panel.setFrame(ActivityHUDLayout.frame(in: visible, profileRows: rows), display: false)
            // Fixed coordinate space scales as one card on very small screens.
            material.setBoundsSize(NSSize(width: 272, height: ActivityHUDLayout.cardHeight(profileRows: rows)))
        }
        panel.orderFrontRegardless() // Never activate Voicepad or change the caret.
    }

    private func updateProfiles(_ state: ProfileSelection?, keyboardAvailable: Bool) {
        profileGrid.isHidden = state == nil
        profileStatus.isHidden = state == nil
        guard let state else { return }
        profileStatus.stringValue = keyboardAvailable ? state.hudStatus
            : (state.loading || state.unavailable ? state.hudStatus : "Click a profile · keys need Accessibility")
        profileStatus.toolTip = keyboardAvailable ? "Press 1–9 for a populated profile; 0 for default raw. Selection at stop is sent."
            : "Keyboard selection unavailable. Click chips without leaving the original app; allow Accessibility for number-key selection."
        let chips = state.chips
        guard chips != displayedChips else { return }
        displayedChips = chips
        for view in profileGrid.arrangedSubviews { profileGrid.removeArrangedSubview(view); view.removeFromSuperview() }
        for offset in stride(from: 0, to: chips.count, by: 3) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 4
            row.distribution = .fillEqually
            for index in offset..<min(offset + 3, chips.count) {
                let chip = chips[index]
                let button = ProfileChipButton(title: chip.title, target: self, action: #selector(selectProfile(_:)))
                button.cell = ProfileChipCell(textCell: chip.title)
                button.target = self
                button.action = #selector(selectProfile(_:))
                button.alignment = .center
                button.translatesAutoresizingMaskIntoConstraints = false
                button.heightAnchor.constraint(equalToConstant: ActivityHUDLayout.profileChipHeight).isActive = true
                button.tag = chip.slot
                button.isBordered = false
                button.focusRingType = .none
                button.font = .systemFont(ofSize: 10, weight: chip.selected ? .semibold : .regular)
                button.contentTintColor = chip.selected ? VoicepadPalette.terracotta : VoicepadPalette.ink
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.backgroundColor = (chip.selected ? VoicepadPalette.terracotta.withAlphaComponent(0.17)
                    : VoicepadPalette.ivory.withAlphaComponent(0.7)).cgColor
                button.layer?.borderWidth = chip.selected ? 1 : 0
                button.layer?.borderColor = VoicepadPalette.terracotta.withAlphaComponent(0.35).cgColor
                button.cell?.lineBreakMode = .byTruncatingTail
                button.toolTip = chip.title + (chip.selected ? " — selected" : "")
                button.setAccessibilityLabel(chip.title + (chip.selected ? ", selected" : ""))
                row.addArrangedSubview(button)
            }
            while row.arrangedSubviews.count < 3 { row.addArrangedSubview(NSView()) }
            profileGrid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: profileGrid.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
    }

    @objc private func selectProfile(_ sender: NSButton) { onProfile?(sender.tag) }

    func showWarning(_ message: String) {
        show(title: "Raw dictation returned", detail: message, canCancel: false)
        heading.font = NSFont(name: "Georgia", size: 17) ?? .systemFont(ofSize: 17)
        dismiss(after: 7)
    }

    func showPasteNotice(clipboardRestored: Bool) {
        show(title: "Paste sent", detail: clipboardRestored
            ? "Clipboard restored · recovery in VP menu"
            : "Clipboard details · recovery in VP menu", canCancel: false)
        // The menu carries the exact unverified-delivery status, not a fake success.
        heading.stringValue = "Paste sent · not verified"
        heading.font = NSFont(name: "Georgia", size: 17) ?? .systemFont(ofSize: 17)
        dismiss(after: FeedbackTiming.pasteNoticeSeconds)
    }

    private func dismiss(after seconds: TimeInterval) {
        let generation = presentationGeneration
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.presentationGeneration == generation else { return }
                self.hide()
            }
        }
        dismissalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide() {
        glyph.reset()
        pinnedVisibleFrame = nil
        presentationGeneration += 1
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        heading.font = NSFont(name: "Georgia", size: 20) ?? .systemFont(ofSize: 20, weight: .medium)
        panel.orderOut(nil)
    }
    @objc private func cancel() { onCancel?() }
}
#endif
