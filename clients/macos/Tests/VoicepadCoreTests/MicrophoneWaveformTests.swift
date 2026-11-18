import XCTest
@testable import VoicepadCore

final class MicrophoneWaveformTests: XCTestCase {
    func testSilenceAndInvalidPowerStayQuiet() {
        var meter = MicrophoneWaveform()
        for power in [-160.0, -.infinity, .nan] { meter.update(decibels: power) }
        XCTAssertEqual(meter.bars, [2, 2, 2, 2, 2])
    }
    func testActualLevelGrowsAndHistoryMoves() {
        var meter = MicrophoneWaveform()
        meter.update(decibels: -10)
        XCTAssertGreaterThan(meter.bars.last!, 10)
        let previous = meter.bars.last!
        meter.update(decibels: -160)
        XCTAssertEqual(meter.bars[3], previous)
        XCTAssertLessThan(meter.bars[4], previous)
        XCTAssertTrue(meter.bars.allSatisfy { (2...24).contains($0) })
    }
    func testLouderInputAndPeakClamp() {
        var quiet = MicrophoneWaveform(), loud = MicrophoneWaveform()
        quiet.update(decibels: -35)
        loud.update(decibels: -5)
        XCTAssertGreaterThan(loud.bars.last!, quiet.bars.last!)
        for _ in 0..<20 { loud.update(decibels: 40) }
        XCTAssertLessThanOrEqual(loud.bars.last!, 24)
    }
    func testResetAndReducedMotionUseNoHistory() {
        var meter = MicrophoneWaveform()
        meter.update(decibels: -5)
        let simplified = meter.heights(reduceMotion: true)
        XCTAssertEqual(Set(simplified).count, 1)
        meter.reset()
        XCTAssertEqual(meter.bars, [2, 2, 2, 2, 2])
    }
}
