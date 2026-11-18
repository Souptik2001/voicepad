#if os(macOS)
import AVFoundation
import Foundation
import VoicepadCore

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    static let maximumBytes = RecordingLimits.maximumBytes
    static let maximumSeconds = RecordingLimits.maximumSeconds
    static let minimumSeconds: TimeInterval = 1

    struct Clip {
        let data: Data
        let seconds: TimeInterval
    }

    enum Failure: LocalizedError {
        case couldNotStart, tooShort, tooLong, tooLarge, encoding
        var errorDescription: String? {
            switch self {
            case .couldNotStart: return "The microphone could not start. Check your selected input device and microphone permission."
            case .tooShort: return "Hold the shortcut for at least one second, then release to transcribe."
            case .tooLong: return "The audio exceeded 600 seconds (10 minutes) and was discarded."
            case .tooLarge: return "The recording exceeded the 25 MiB upload limit and was discarded."
            case .encoding: return "Audio encoding failed. The recording was discarded."
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var temporaryDirectory: URL?
    var onFailure: ((Error) -> Void)?
    var onDurationLimit: (() -> Void)?
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
    /// Meter the existing capture; never starts another microphone session.
    var averagePower: Double {
        guard let recorder, recorder.isRecording else { return -160 }
        recorder.updateMeters()
        return Double(recorder.averagePower(forChannel: 0))
    }
    var fileBytes: Int {
        guard let fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    func start() throws {
        purge()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev.voicepad.mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        temporaryDirectory = directory
        let url = directory.appendingPathComponent("recording.m4a")
        fileURL = url
        do {
            let audio = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            audio.delegate = self
            audio.isMeteringEnabled = true
            recorder = audio
            // Leave a small allowance for AAC encoder padding so decoding the
            // container at the backend still stays inside its hard 600s limit.
            guard audio.prepareToRecord(), audio.record(forDuration: RecordingLimits.captureSeconds) else { throw Failure.couldNotStart }
        } catch {
            purge()
            throw error
        }
    }

    func finish() throws -> Clip {
        guard let audio = recorder, let url = fileURL else { throw Failure.couldNotStart }
        audio.delegate = nil
        audio.stop() // Finalize the AAC container before reading it.
        recorder = nil
        defer { purge() }
        // currentTime may reset to zero after an automatic duration-limit stop.
        // Read the finalized container's duration without playing any audio.
        let seconds = try AVAudioPlayer(contentsOf: url).duration
        guard seconds >= Self.minimumSeconds else { throw Failure.tooShort }
        guard RecordingLimits.acceptsDuration(seconds) else { throw Failure.tooLong }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 0 else { throw Failure.encoding }
        guard bytes <= Self.maximumBytes else { throw Failure.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return Clip(data: data, seconds: seconds)
    }

    func purge() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        fileURL = nil
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.onFailure?(error ?? Failure.encoding)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            // A normal user stop clears the delegate first. The recorder enforces
            // the 600-second bound even while the menu is tracking a mouse event.
            if flag {
                self.onDurationLimit?()
            } else {
                self.onFailure?(Failure.encoding)
            }
        }
    }
}
#endif
