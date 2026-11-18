#if os(macOS)
import AppKit
import VoicepadCore

/// Original, short in-memory cues. No files, network, extra capture or system alert.
@MainActor
final class FeedbackPlayer {
    private var sounds: [String: NSSound] = [:]
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEffectsEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "soundEffectsEnabled")
            if !newValue { stop() }
        }
    }

    /// Returns the playback budget so capture can start after the start cue ends.
    @discardableResult
    func play(_ cue: FeedbackCue) -> TimeInterval {
        stop()
        guard enabled else { return 0 }
        let sound: NSSound
        let key = String(describing: cue)
        if let existing = sounds[key] { sound = existing }
        else {
            guard let generated = NSSound(data: cue.wavData()) else { return 0 }
            sounds[key] = generated
            sound = generated
        }
        sound.volume = 0.65
        guard sound.play() else { return 0 }
        return cue.duration + 0.04
    }

    func stop() {
        for sound in sounds.values { sound.stop() }
    }
}
#endif
