import Foundation

/// Five-sample, smoothed level history, not a frequency spectrum or raw waveform.
public struct MicrophoneWaveform {
    public private(set) var bars: [Double] = Array(repeating: 2, count: 5)
    private var envelope: Double = 0
    public init() {}
    public mutating func update(decibels: Double) {
        let target: Double
        if decibels.isFinite {
            target = min(1, max(0, (decibels + 50) / 50))
        } else { target = 0 }
        // Fast speech attack with a softer release; silence naturally settles.
        let smoothing = target > envelope ? 0.72 : 0.32
        envelope += (target - envelope) * smoothing
        if envelope < 0.005 { envelope = 0 }
        bars.removeFirst()
        bars.append(2 + envelope * 22)
    }
    public func heights(reduceMotion: Bool) -> [Double] {
        reduceMotion ? Array(repeating: bars.last ?? 2, count: 5) : bars
    }
    public mutating func reset() {
        envelope = 0
        bars = Array(repeating: 2, count: 5)
    }
}
