#if os(macOS)
import AppKit
import AVFoundation
import VoicepadCore

private final class PrivateServiceSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward voice audio into an identity-provider/proxy redirect.
        completionHandler(nil)
    }
}

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private enum Origin { case shortcut, toggle, menu }
    private struct PendingAudio {
        let clip: AudioRecorder.Clip
        let expires: Date
        let profileSlot: Int?
    }

    private let networkSession: URLSession
    private let api: VoicepadAPI
    private var session = RecordingSession()
    private let recorder = AudioRecorder()
    private let shortcut = ShortcutController()
    private let hud = ActivityHUD()
    private let feedback = FeedbackPlayer()
    private var soundItem: NSMenuItem!
    private let profileKeys = ProfileKeyController()
    private var profiles = ProfileSelection(savedSlot: UserDefaults.standard.object(forKey: "profileSlot") as? Int)
    private var profileTask: Task<Void, Never>?
    private var profileDeadline: Task<Void, Never>?
    private var profileKeyboardAvailable = false
    private let transcriptPanel = TranscriptPanel()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let connectionItem = NSMenuItem(title: "Connection: checking…", action: nil, keyEquivalent: "")
    private let providerItem = NSMenuItem(title: "Provider: unknown", action: nil, keyEquivalent: "")
    private let messageItem = NSMenuItem(title: "Double-tap Command to start; double-tap again to transcribe.", action: nil, keyEquivalent: "")
    private let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
    private var recordItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var enableDetectionItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var retryItem: NSMenuItem!
    private var discardItem: NSMenuItem!
    private var copyItem: NSMenuItem!
    private var resultItem: NSMenuItem!
    private var presetItems: [NSMenuItem] = []
    private var operation: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var timer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var localEscape: Any?
    private var globalEscape: Any?
    private var origin: Origin?
    private var held = false
    private var target: TextInserter.Target?
    private var targetFailureReason: String?
    private var pasting = false
    private var pending: PendingAudio?
    private var lastTranscript: String?
    private var uploadStarted: Date?
    private var shuttingDown = false
    private var statusGeneration = 0

    override init() {
        // Audio, transcripts, cookies and credentials must not be cached to disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = RecordingLimits.requestTimeout
        configuration.timeoutIntervalForResource = RecordingLimits.resourceTimeout
        let network = URLSession(configuration: configuration,
                                 delegate: PrivateServiceSessionDelegate(), delegateQueue: nil)
        networkSession = network
        api = VoicepadAPI(session: network)
        super.init()
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "VP"
        statusItem.button?.setAccessibilityLabel("Voicepad menu")
        statusItem.button?.toolTip = "Voicepad — double-tap Command to start / stop"
        menu.autoenablesItems = false
        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
        recorder.onFailure = { [weak self] error in self?.failRecording(error) }
        recorder.onDurationLimit = { [weak self] in self?.finishRecording() }
        shortcut.onPressed = { [weak self] in
            guard let self else { return }
            self.held = true
            // Capture before showing the HUD or touching a Voicepad window.
            let capture = TextInserter.captureTarget()
            self.beginRecording(origin: .shortcut, target: capture.target, failureReason: capture.failureReason)
        }
        shortcut.onReleased = { [weak self] in
            guard let self else { return }
            self.held = false
            guard self.origin == .shortcut else { return }
            switch self.session.phase {
            case .recording: self.finishRecording()
            case .requestingPermission: self.cancelActive(message: "Released before permission was granted. Hold the shortcut again to record.")
            default: break
            }
        }
        shortcut.onToggle = { [weak self] in self?.toggleRecording() }
        shortcut.onReset = { [weak self] message in self?.cancelActive(message: message) }
        hud.onProfile = { [weak self] slot in self?.chooseProfile(slot) }
        profileKeys.onKey = { [weak self] key, modified in
            guard let self, self.session.phase == .recording,
                  let slot = self.profiles.slotForKey(keyCode: key, modified: modified) else { return false }
            return self.chooseProfile(slot)
        }
        profileKeys.onUnavailable = { [weak self] in
            self?.profileKeyboardAvailable = false
            self?.tick()
        }
        hud.onCancel = { [weak self] in self?.cancelActive() }
        transcriptPanel.onCopy = { [weak self] in self?.copyTranscript() }
        let saved = ShortcutController.initialPreset()
        bindShortcut(saved)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shortcut.suspend()
                    self?.cancelActive(message: "Cancelled because the Mac is sleeping or the session became inactive.")
                    self?.discardPending()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.shuttingDown else { return }
                    do { try self.shortcut.resume() }
                    catch { self.setMessage(error.localizedDescription) }
                    self.updateMenu()
                }
            })
        }
        updateMenu()
        refreshStatus()
    }

    private func buildMenu() {
        menu.addItem(connectionItem)
        menu.addItem(providerItem)
        menu.addItem(messageItem)
        menu.addItem(.separator())
        recordItem = add("Start Recording (click Stop to send)", #selector(menuRecord))
        stopItem = add("Stop & Transcribe", #selector(menuStop))
        cancelItem = add("Cancel Recording / Upload", #selector(menuCancel))
        retryItem = add("Retry Failed Upload", #selector(menuRetry))
        discardItem = add("Discard Retained Audio", #selector(menuDiscard))
        menu.addItem(.separator())
        copyItem = add("Copy Last Transcript", #selector(copyTranscript))
        resultItem = add("Show Last Transcript…", #selector(showTranscript))
        menu.addItem(shortcutItem)
        let presets = NSMenu()
        presets.autoenablesItems = false
        for preset in ShortcutController.Preset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(changeShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            presets.addItem(item)
            presetItems.append(item)
        }
        shortcutItem.submenu = presets
        enableDetectionItem = add("Enable Double-Command Detection…", #selector(enableDoubleCommand))
        add("Permissions…", #selector(permissions))
        soundItem = add("Sound Effects", #selector(toggleSoundEffects))
        soundItem.state = feedback.enabled ? .on : .off
        menu.addItem(.separator())
        add("Open Dashboard in Browser", #selector(openDashboard))
        add("Open Admin / Sign In in Browser", #selector(openAdmin))
        add("Refresh Connection Status", #selector(refreshConnection))
        menu.addItem(.separator())
        add("Quit Voicepad", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        shortcut.checkHealth()
        updateMenu()
        refreshStatus() // Status checks never request microphone, Input Monitoring or Accessibility access.
    }

    private var active: Bool {
        switch session.phase {
        case .idle: return false
        default: return true
        }
    }

    private func updateMenu() {
        let recording: Bool
        switch session.phase { case .recording: recording = true; default: recording = false }
        recordItem?.isEnabled = !active
        stopItem?.isEnabled = recording
        cancelItem?.isEnabled = active
        retryItem?.isEnabled = !active && pending != nil
        discardItem?.isEnabled = pending != nil
        copyItem?.isEnabled = lastTranscript != nil
        resultItem?.isEnabled = lastTranscript != nil
        shortcutItem.isEnabled = !active
        for item in presetItems { item.state = item.tag == shortcut.preset?.rawValue ? .on : .off }
        let shortcutTitle = shortcut.preset?.title ?? "not selected"
        shortcutItem.title = "Shortcut: \(shortcutTitle)\(shortcut.isArmed ? "" : " — not armed")"
        enableDetectionItem?.isEnabled = !active
        statusItem?.button?.title = active ? (recording ? "● VP" : "… VP") : "VP"
        statusItem?.button?.toolTip = "Voicepad — \(shortcutTitle)\(shortcut.isArmed ? "" : " — not armed; enable detection or use menu")"
    }

    private func setMessage(_ text: String) {
        // Never put the transcript in the menu; error descriptions are bounded.
        messageItem.title = String(text.prefix(160))
        messageItem.toolTip = text
    }

    private func beginRecording(origin: Origin, target: TextInserter.Target?, failureReason: String? = nil) {
        guard !shuttingDown, let generation = session.begin() else { return }
        discardPending()
        self.origin = origin
        self.target = target
        self.targetFailureReason = failureReason
        hud.hide() // A previous brief notice must not pin a new session to its display.
        hud.show(title: "Microphone permission", detail: "Waiting for microphone access…")
        installEscapeMonitors()
        setMessage("Preparing microphone…")
        updateMenu()
        operation = Task { [weak self] in
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: allowed = true
            case .notDetermined:
                allowed = await AVCaptureDevice.requestAccess(for: .audio)
            default: allowed = false
            }
            guard let self, !Task.isCancelled, self.session.generation == generation,
                  !self.shuttingDown else { return }
            guard allowed else {
                self.cancelActive(message: "Microphone access is required. Open Permissions to enable it in System Settings.")
                return
            }
            if origin == .shortcut && !self.held {
                self.cancelActive(message: "Hold the shortcut again to record.")
                return
            }
            do {
                // Play before opening capture so the cue is not transcribed.
                let cueDelay = self.feedback.play(.recordingStarted)
                if cueDelay > 0 {
                    self.hud.show(title: "Starting microphone", detail: "Ready in a moment…")
                    try await Task.sleep(nanoseconds: UInt64(cueDelay * 1_000_000_000))
                }
                guard !Task.isCancelled, !self.shuttingDown, self.session.generation == generation,
                      self.session.phase == .requestingPermission else { return }
                if origin == .shortcut && !self.held {
                    self.cancelActive(message: "Released before recording began. Hold again to record.")
                    return
                }
                guard self.session.permissionGranted(for: generation) else { return }
                try self.recorder.start()
                self.operation = nil
                self.startProfiles() // Never await the network before starting the mic.
                self.startTimer()
                self.tick()
                self.setMessage(origin == .toggle
                    ? "Recording. Double-tap Command to send, or click Stop & Transcribe."
                    : origin == .shortcut ? "Recording. Release the shortcut to send."
                    : "Recording. Click Stop & Transcribe to send.")
                self.updateMenu()
            } catch {
                guard !Task.isCancelled, self.session.generation == generation, !self.shuttingDown else { return }
                self.failRecording(error)
            }
        }
    }

    private func startProfiles() {
        stopProfileLoading()
        let token = profiles.begin()
        profileKeyboardAvailable = profileKeys.start()
        profileTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.api.profiles()
                guard !Task.isCancelled, !self.shuttingDown, self.session.phase == .recording,
                      try self.profiles.loaded(catalog, for: token) else { return }
                self.profileDeadline?.cancel()
                self.profileDeadline = nil
                self.profileTask = nil
                self.persistProfile()
                self.tick()
            } catch {
                guard !Task.isCancelled else { return }
                self.profilesFailed(token: token)
            }
        }
        // URLRequest timeout is an inactivity timeout, not a wall-clock budget.
        // This independent deadline bounds even a trickling server response.
        profileDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.profilesFailed(token: token)
        }
    }

    private func profilesFailed(token: Int) {
        guard !shuttingDown, session.phase == .recording, profiles.failed(for: token) else { return }
        stopProfileLoading()
        persistProfile()
        setMessage("Profiles unavailable. Recording continues with default raw dictation; no custom profile will be sent.")
        tick()
    }

    private func stopProfileLoading() {
        profileTask?.cancel()
        profileTask = nil
        profileDeadline?.cancel()
        profileDeadline = nil
    }

    private func persistProfile() {
        if let slot = profiles.savedSlot { UserDefaults.standard.set(slot, forKey: "profileSlot") }
        else { UserDefaults.standard.removeObject(forKey: "profileSlot") }
    }

    @discardableResult
    private func chooseProfile(_ slot: Int) -> Bool {
        guard session.phase == .recording, profiles.select(slot) else { return false }
        shortcut.interruptGesture() // Swallowed digits interrupt partial Command taps, not hold/release.
        persistProfile()
        Task { @MainActor [weak self] in self?.tick() }
        return true
    }

    private func finishRecording() {
        guard case .recording = session.phase else { return }
        timer?.invalidate()
        timer = nil
        do {
            let clip = try recorder.finish()
            guard let generation = session.finish() else { cancelActive(); return }
            feedback.play(.recordingStopped) // Capture has already closed.
            origin = nil
            let profileSlot = profiles.stop() // Selection at STOP, not recording start.
            persistProfile()
            stopProfileLoading()
            profileKeys.stop()
            send(clip, generation: generation, insertionTarget: target, failureReason: targetFailureReason, profileSlot: profileSlot)
        } catch { failRecording(error) }
    }

    private func send(_ clip: AudioRecorder.Clip, generation: Int, insertionTarget: TextInserter.Target?, failureReason: String? = nil, profileSlot: Int? = nil) {
        uploadStarted = Date()
        hud.show(title: "Transcribing", detail: "Sending audio securely to Voicepad…")
        setMessage("Transcribing… Cancel stops this client from accepting the response.")
        startTimer()
        updateMenu()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.api.transcribe(audio: clip.data, mimeType: "audio/mp4", profileSlot: profileSlot)
                guard !Task.isCancelled, !self.shuttingDown,
                      self.session.generation == generation, self.session.phase == .uploading else { return }
                let text = transcript.text
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    guard self.session.complete(for: generation) else { return }
                    self.operation = nil
                    self.discardPending()
                    self.finishActivity()
                    self.setMessage("No speech was returned. The recording was discarded.")
                    self.updateMenu()
                    return
                }
                self.lastTranscript = text
                // Stay uploading/active until confirmation ends. No overlapping
                // recording may take over temporary clipboard ownership.
                self.pasting = true
                self.hud.hide() // Don't keep the recording box over the editor during clipboard cleanup.
                self.setMessage("Requesting paste into the original field…")
                let result = await TextInserter.insert(text, into: insertionTarget, failureReason: failureReason,
                    isCurrent: { [weak self] in
                        guard let self else { return false }
                        return !self.shuttingDown && self.session.generation == generation
                            && self.session.phase == .uploading
                    })
                // Never clear a newer session's task/HUD or show a stale popup.
                guard !Task.isCancelled, !self.shuttingDown,
                      self.session.complete(for: generation) else { return }
                self.operation = nil
                self.discardPending()
                self.finishActivity()
                let message = transcript.deliveryMessage(result.message)
                // A formatting warning must not activate a window before insertion,
                // replace the transcript, or hide the actual delivery/clipboard status.
                self.transcriptPanel.setTranscript(text, message: message, show: result.showTranscript)
                if result.confirmed { self.feedback.play(.pasted) }
                if transcript.warning != nil {
                    self.hud.showWarning(message)
                } else if result.showNotice { self.hud.showPasteNotice(clipboardRestored: result.clipboardRestored) }
                self.setMessage(message)
                self.updateMenu()
            } catch {
                guard !Task.isCancelled, !self.shuttingDown,
                      self.session.complete(for: generation) else { return }
                self.operation = nil
                self.finishActivity()
                self.retainFailed(clip, profileSlot: profileSlot)
                self.setMessage("Upload failed: \(error.localizedDescription). Retry or Discard; audio expires after 120 seconds.")
                self.updateMenu()
            }
        }
    }

    private func retainFailed(_ clip: AudioRecorder.Clip, profileSlot: Int?) {
        guard pending == nil else { return } // A retry does not extend retention.
        let deadline = Date().addingTimeInterval(120)
        pending = PendingAudio(clip: clip, expires: deadline, profileSlot: profileSlot)
        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.pending?.expires == deadline else { return }
            if self.active { self.cancelActive(message: "Retained audio expired and was discarded.") }
            self.discardPending()
            self.setMessage("Failed-upload audio expired and was discarded. Record again to retry.")
            self.updateMenu()
        }
    }

    private func discardPending() {
        expirationTask?.cancel()
        expirationTask = nil
        pending = nil
        updateMenu()
    }

    private func failRecording(_ error: Error) {
        cancelActive(message: error.localizedDescription)
    }

    private func cancelActive(message: String = "Cancelled. Audio discarded. A paste already requested may have arrived; check the field before pasting again.") {
        operation?.cancel()
        feedback.stop()
        TextInserter.cancel() // Synchronous pre-dispatch cleanup also works at quit.
        operation = nil
        session.cancel() // Invalidates late permission and network completions.
        profiles.cancel()
        stopProfileLoading()
        profileKeys.stop()
        shortcut.resetInput() // No gesture tail or queued shortcut can survive cancellation.
        recorder.purge()
        discardPending()
        held = false
        finishActivity()
        setMessage(message)
        updateMenu()
    }

    private func finishActivity() {
        timer?.invalidate()
        timer = nil
        hud.hide()
        removeEscapeMonitors()
        target = nil
        targetFailureReason = nil
        pasting = false
        origin = nil
        uploadStarted = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        switch session.phase {
        case .recording:
            if recorder.fileBytes > AudioRecorder.maximumBytes {
                failRecording(AudioRecorder.Failure.tooLarge)
                return
            }
            let seconds = recorder.elapsed
            if seconds >= AudioRecorder.maximumSeconds { finishRecording(); return }
            let instruction = origin == .toggle ? "Double-tap Command to send"
                : origin == .shortcut ? "Release to send" : "Use Stop & Transcribe in menu"
            hud.show(title: "Recording", detail: instruction, elapsed: seconds, microphonePower: recorder.averagePower, profileSelection: profiles, profileKeyboardAvailable: profileKeyboardAvailable)
        case .uploading:
            guard !pasting else { return } // Leave the editor clear while safe clipboard restoration finishes.
            let elapsed = Date().timeIntervalSince(uploadStarted ?? Date())
            hud.show(title: pasting ? "Pasting" : "Transcribing", detail: pasting
                ? "Clipboard handled with care"
                : "A moment for your thoughts", elapsed: elapsed)
        default: break
        }
    }

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        localEscape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only inspect Escape while an operation is active; never record keys.
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.cancelActive() }
            return nil
        }
        // Do not request Input Monitoring/Accessibility just to watch Escape.
        if TextInserter.isTrusted {
            globalEscape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in self?.cancelActive() }
            }
        }
    }

    private func removeEscapeMonitors() {
        if let localEscape { NSEvent.removeMonitor(localEscape) }
        if let globalEscape { NSEvent.removeMonitor(globalEscape) }
        localEscape = nil
        globalEscape = nil
    }

    private func refreshStatus() {
        statusTask?.cancel()
        statusGeneration += 1
        let generation = statusGeneration
        statusTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await self.api.status()
                guard !Task.isCancelled, !self.shuttingDown, self.statusGeneration == generation else { return }
                self.connectionItem.title = status.credentialAvailable ? "Connection: ready" : "Connection: backend reachable; sign in required"
                self.connectionItem.toolTip = nil
                self.providerItem.title = "Provider: \(status.provider)"
                self.providerItem.toolTip = status.credentialExpiresAt.map { "Credential expires: \($0)" }
            } catch {
                guard !Task.isCancelled, !self.shuttingDown, self.statusGeneration == generation else { return }
                self.connectionItem.title = "Connection: unavailable — check Tailscale / backend"
                self.connectionItem.toolTip = error.localizedDescription
                self.providerItem.title = "Provider: unknown"
                self.providerItem.toolTip = nil
            }
            self.statusTask = nil
        }
    }

    private func bindShortcut(_ preset: ShortcutController.Preset) {
        held = false
        UserDefaults.standard.set(preset.rawValue, forKey: "shortcutPreset")
        UserDefaults.standard.set(1, forKey: "shortcutModeVersion")
        do {
            try shortcut.register(preset)
            setMessage(preset == .doubleCommand
                ? "Double-tap the same Command key to start; double-tap again to transcribe."
                : "\(preset.title) to record; release to transcribe.")
        } catch { setMessage(error.localizedDescription) }
        updateMenu()
    }

    private func toggleRecording() {
        guard !shuttingDown else { return }
        switch session.phase.toggleAction {
        case .begin:
            // Capture at toggle START, before the HUD or any Voicepad window.
            let capture = TextInserter.captureTarget()
            beginRecording(origin: .toggle, target: capture.target, failureReason: capture.failureReason)
        case .finish: finishRecording()
        case .cancel:
            cancelActive(message: "Cancelled while waiting for microphone access. Double-tap Command to try again.")
        case .ignore: break // Never duplicate an in-flight upload.
        }
    }

    @objc private func enableDoubleCommand() {
        guard !active else { return }
        guard PermissionPresentation.enableDoubleCommand() else { return }
        bindShortcut(.doubleCommand) // Explicit retry also handles permission regrant.
    }

    @objc private func menuRecord() { beginRecording(origin: .menu, target: nil) }
    @objc private func menuStop() { finishRecording() }
    @objc private func menuCancel() { cancelActive() }
    @objc private func menuRetry() {
        guard !active, let pending else { return }
        guard pending.expires > Date() else {
            discardPending()
            setMessage("Retained audio expired. Record again.")
            return
        }
        guard let generation = session.begin(), session.permissionGranted(for: generation),
              session.finish() != nil else { cancelActive(); return }
        // A menu retry is explicit, but never silently inserts into an old field.
        target = nil
        installEscapeMonitors()
        send(pending.clip, generation: generation, insertionTarget: nil, profileSlot: pending.profileSlot)
    }
    @objc private func menuDiscard() {
        if active { cancelActive() } else { discardPending() }
        setMessage("Retained audio discarded.")
    }
    @objc private func copyTranscript() {
        guard let lastTranscript else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if clipboard.setString(lastTranscript, forType: .string) {
            setMessage("Transcript copied. Clipboard remains changed until you replace it.")
        } else { setMessage("Copy failed. Select and copy text in Show Last Transcript.") }
    }
    @objc private func showTranscript() { transcriptPanel.showExplicitly() }
    @objc private func changeShortcut(_ item: NSMenuItem) {
        guard !active, let preset = ShortcutController.Preset(rawValue: item.tag) else { return }
        bindShortcut(preset)
    }
    @objc private func toggleSoundEffects() {
        feedback.enabled.toggle()
        soundItem.state = feedback.enabled ? .on : .off
    }
    @objc private func permissions() { PermissionPresentation.show() }
    @objc private func refreshConnection() { refreshStatus() }
    @objc private func openDashboard() { NSWorkspace.shared.open(VoicepadAPI.serviceURL) }
    @objc private func openAdmin() { NSWorkspace.shared.open(VoicepadAPI.serviceURL.appendingPathComponent("admin")) }
    @objc private func quit() { NSApp.terminate(nil) }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        cancelActive()
        statusTask?.cancel()
        statusTask = nil
        networkSession.invalidateAndCancel()
        shortcut.shutdown()
        transcriptPanel.clear()
        lastTranscript = nil
        for token in notificationTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notificationTokens.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
#endif
