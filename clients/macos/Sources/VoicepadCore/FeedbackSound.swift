import Foundation

/// Short, original, in-memory feedback; never reads assets or microphone audio.
public enum FeedbackCue: CaseIterable {
    case recordingStarted
    case recordingStopped
    case pasted

    public var duration: TimeInterval {
        switch self {
        case .recordingStarted: return 0.12
        case .recordingStopped: return 0.10
        case .pasted: return 0.14
        }
    }

    /// Mono 22,050 Hz signed 16-bit little-endian PCM in a standard RIFF container.
    public func wavData() -> Data {
        let sampleRate = 22_050
        let sampleCount = Int((duration * Double(sampleRate)).rounded())
        let byteCount = sampleCount * 2
        var data = Data()
        data.reserveCapacity(44 + byteCount)
        func appendLE(_ value: UInt32, bytes: Int) {
            for index in 0..<bytes {
                data.append(UInt8(truncatingIfNeeded: value >> (index * 8)))
            }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + byteCount), bytes: 4)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(16, bytes: 4)
        appendLE(1, bytes: 2) // Integer PCM.
        appendLE(1, bytes: 2) // Mono.
        appendLE(UInt32(sampleRate), bytes: 4)
        appendLE(UInt32(sampleRate * 2), bytes: 4)
        appendLE(2, bytes: 2)
        appendLE(16, bytes: 2)
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(byteCount), bytes: 4)
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let progress = Double(index) / Double(sampleCount - 1)
            // A raised-sine envelope reaches zero with zero slope at both ends.
            let taper = sin(Double.pi * progress)
            let envelope = taper * taper
            let wave: Double
            switch self {
            case .recordingStarted, .recordingStopped:
                let start = self == .recordingStarted ? 440.0 : 780.0
                let end = self == .recordingStarted ? 980.0 : 340.0
                // Integrate the linear frequency sweep to avoid phase discontinuities.
                let phase = 2 * Double.pi * (start * time + (end - start) * time * time / (2 * duration))
                wave = 0.105 * (sin(phase) + 0.12 * sin(2.01 * phase))
            case .pasted:
                // A quiet perfect-fourth dyad, not a recording or a system sound.
                wave = 0.065 * sin(2 * Double.pi * 660 * time)
                    + 0.050 * sin(2 * Double.pi * 880 * time)
            }
            let sample = wave * envelope
            // Guard before integer conversion; leave ample headroom even if synthesis changes.
            let safeSample = sample.isFinite ? min(0.24, max(-0.24, sample)) : 0
            let pcm = Int16((safeSample * Double(Int16.max)).rounded())
            appendLE(UInt32(UInt16(bitPattern: pcm)), bytes: 2)
        }
        return data
    }
}

public enum FeedbackTiming {
    public static let pasteNoticeSeconds: TimeInterval = 0.65
}
