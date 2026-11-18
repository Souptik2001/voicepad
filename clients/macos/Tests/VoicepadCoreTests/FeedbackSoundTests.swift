import Foundation
import XCTest
import VoicepadCore

final class FeedbackSoundTests: XCTestCase {
    func testCuesHaveShortDurationsAndFasterPasteNotice() {
        XCTAssertEqual(FeedbackCue.allCases, [.recordingStarted, .recordingStopped, .pasted])
        XCTAssertEqual(FeedbackCue.recordingStarted.duration, 0.12, accuracy: 0.0001)
        XCTAssertEqual(FeedbackCue.recordingStopped.duration, 0.10, accuracy: 0.0001)
        XCTAssertEqual(FeedbackCue.pasted.duration, 0.14, accuracy: 0.0001)
        XCTAssertEqual(FeedbackTiming.pasteNoticeSeconds, 0.65, accuracy: 0.0001)
    }

    func testWAVHasConsistentLittleEndianMonoSigned16PCMHeader() {
        for cue in FeedbackCue.allCases {
            let bytes = Array(cue.wavData())
            let sampleCount = Int((cue.duration * 22_050).rounded())
            XCTAssertEqual(bytes.count, 44 + sampleCount * 2)
            guard bytes.count >= 44 else { continue }
            XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
            XCTAssertEqual(readLE(bytes, at: 4, count: 4), bytes.count - 8)
            XCTAssertEqual(String(bytes: bytes[8..<12], encoding: .ascii), "WAVE")
            XCTAssertEqual(String(bytes: bytes[12..<16], encoding: .ascii), "fmt ")
            XCTAssertEqual(readLE(bytes, at: 16, count: 4), 16)
            XCTAssertEqual(readLE(bytes, at: 20, count: 2), 1) // Integer PCM, not float.
            XCTAssertEqual(readLE(bytes, at: 22, count: 2), 1)
            XCTAssertEqual(readLE(bytes, at: 24, count: 4), 22_050)
            XCTAssertEqual(readLE(bytes, at: 28, count: 4), 44_100)
            XCTAssertEqual(readLE(bytes, at: 32, count: 2), 2)
            XCTAssertEqual(readLE(bytes, at: 34, count: 2), 16)
            XCTAssertEqual(String(bytes: bytes[36..<40], encoding: .ascii), "data")
            XCTAssertEqual(readLE(bytes, at: 40, count: 4), sampleCount * 2)
        }
    }

    func testDecodedSignalsAreQuietFiniteBipolarAndSmoothAtBothEnds() {
        for cue in FeedbackCue.allCases {
            let samples = decodedSamples(cue)
            XCTAssertFalse(samples.isEmpty)
            guard !samples.isEmpty else { continue }
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) < 0.25 })
            XCTAssertGreaterThan(samples.max() ?? 0, 0.01)
            XCTAssertLessThan(samples.min() ?? 0, -0.01)
            XCTAssertEqual(samples.first, 0)
            XCTAssertEqual(samples.last, 0)
            XCTAssertTrue(samples.prefix(16).allSatisfy { abs($0) < 0.002 })
            XCTAssertTrue(samples.suffix(16).allSatisfy { abs($0) < 0.002 })
            XCTAssertLessThan(zip(samples, samples.dropFirst()).map { abs($0 - $1) }.max() ?? 1, 0.08)
            XCTAssertLessThan(abs(samples.reduce(0, +) / Double(samples.count)), 0.001)
        }
    }

    func testActualWaveformsHaveUpwardAndDownwardSweepsAndSuccessDyad() {
        let upward = decodedSamples(.recordingStarted)
        let downward = decodedSamples(.recordingStopped)
        XCTAssertGreaterThan(crossings(upward, from: 0.6, to: 0.8), crossings(upward, from: 0.2, to: 0.4))
        XCTAssertLessThan(crossings(downward, from: 0.6, to: 0.8), crossings(downward, from: 0.2, to: 0.4))
        let success = decodedSamples(.pasted)
        let lowerTone = magnitude(success, at: 660)
        let upperTone = magnitude(success, at: 880)
        XCTAssertGreaterThan(lowerTone, 0.01)
        XCTAssertGreaterThan(upperTone, 0.01)
        XCTAssertGreaterThan(lowerTone, 3 * magnitude(success, at: 550))
        XCTAssertGreaterThan(upperTone, 3 * magnitude(success, at: 990))
        XCTAssertEqual(Set(FeedbackCue.allCases.map { $0.wavData() }).count, 3)
        for cue in FeedbackCue.allCases { XCTAssertEqual(cue.wavData(), cue.wavData()) }
    }

    private func readLE(_ bytes: [UInt8], at offset: Int, count: Int) -> Int {
        (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
    }

    private func decodedSamples(_ cue: FeedbackCue) -> [Double] {
        let bytes = Array(cue.wavData())
        guard bytes.count >= 44, (bytes.count - 44).isMultiple(of: 2) else {
            XCTFail("Expected a complete PCM WAV for \(cue)")
            return []
        }
        return stride(from: 44, to: bytes.count, by: 2).map {
            Double(Int16(bitPattern: UInt16(readLE(bytes, at: $0, count: 2)))) / 32_768
        }
    }

    private func crossings(_ samples: [Double], from start: Double, to end: Double) -> Int {
        let window = samples[Int(Double(samples.count) * start)..<Int(Double(samples.count) * end)]
        return zip(window, window.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
    }

    private func magnitude(_ samples: [Double], at frequency: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        var real = 0.0, imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 22_050
            real += sample * cos(phase)
            imaginary += sample * sin(phase)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }
}
