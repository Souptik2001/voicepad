import XCTest
@testable import VoicepadCore

final class CommandDoubleTapDetectorTests: XCTestCase {
    private typealias Detector = CommandDoubleTapDetector
    private func tap(_ detector: inout Detector, _ time: Double,
                     key: Detector.Key = .left, hold: Double = 0.05,
                     modifiers: Detector.Modifiers = []) -> Bool {
        XCTAssertFalse(detector.receive(.command(key, down: true, modifiers: modifiers.union(.command)), at: time))
        return detector.receive(.command(key, down: false, modifiers: modifiers), at: time + hold)
    }

    func testRejectsHoldsLongerThanPointThreeSeconds() {
        for longTap in [0, 1] {
            var detector = Detector()
            XCTAssertFalse(tap(&detector, 1, hold: longTap == 0 ? 0.301 : 0.05))
            XCTAssertFalse(tap(&detector, 1.4, hold: longTap == 1 ? 0.301 : 0.05))
        }
    }

    func testGapIsMeasuredFromFirstReleaseToSecondPress() {
        var detector = Detector()
        XCTAssertFalse(tap(&detector, 1, hold: 0.3))
        XCTAssertTrue(tap(&detector, 1.65, hold: 0.3))
        XCTAssertFalse(tap(&detector, 3))
        XCTAssertFalse(tap(&detector, 3.401))
    }

    func testMismatchedPhysicalKeysCannotPair() {
        var detector = Detector()
        XCTAssertFalse(tap(&detector, 1, key: .left))
        XCTAssertFalse(tap(&detector, 1.2, key: .right))
        XCTAssertFalse(tap(&detector, 1.4, key: .right))
        XCTAssertTrue(tap(&detector, 1.6, key: .right))
    }

    func testInterruptionInvalidatesAtAnyPoint() {
        // keyDown (including Cmd+C / Cmd+Tab), mouse down and mouse drag all
        // map to this content-free event; no ordinary key identity is retained.
        for position in 1...3 {
            var detector = Detector()
            let events: [Detector.Event] = [
                .command(.left, down: true, modifiers: [.command]),
                .command(.left, down: false, modifiers: []),
                .command(.left, down: true, modifiers: [.command]),
                .command(.left, down: false, modifiers: [])
            ]
            var time = 1.0
            for (index, event) in events.enumerated() {
                if index == position {
                    XCTAssertFalse(detector.receive(.interruption, at: time))
                    time += 0.01
                }
                XCTAssertFalse(detector.receive(event, at: time))
                time += 0.05
            }
        }
    }

    func testOtherModifierInvalidatesEvenWhenReleasedBeforeCommand() {
        var detector = Detector()
        XCTAssertFalse(tap(&detector, 1))
        XCTAssertFalse(detector.receive(.modifiers([.other]), at: 1.1))
        XCTAssertFalse(detector.receive(.modifiers([]), at: 1.15))
        XCTAssertFalse(tap(&detector, 1.2))
        XCTAssertTrue(tap(&detector, 1.4))
        XCTAssertFalse(tap(&detector, 2, modifiers: [.other]))
        XCTAssertFalse(tap(&detector, 2.2))
    }

    func testCapsLockIsIgnored() {
        var detector = Detector()
        XCTAssertFalse(tap(&detector, 1, modifiers: [.capsLock]))
        XCTAssertFalse(detector.receive(.modifiers([]), at: 1.1))
        XCTAssertTrue(tap(&detector, 1.2))
    }

    func testDuplicatePressAndMismatchedReleaseInvalidate() {
        for invalid in [Detector.Event.command(.left, down: true, modifiers: [.command]),
                        .command(.right, down: false, modifiers: [])] {
            var detector = Detector()
            XCTAssertFalse(tap(&detector, 1))
            XCTAssertFalse(detector.receive(.command(.left, down: true, modifiers: [.command]), at: 1.2))
            XCTAssertFalse(detector.receive(invalid, at: 1.21))
            XCTAssertFalse(detector.receive(.command(.left, down: false, modifiers: []), at: 1.25))
            XCTAssertFalse(tap(&detector, 1.4))
            XCTAssertTrue(tap(&detector, 1.6))
        }
    }

    func testStaleAndNonfiniteTimestampsInvalidate() {
        for time in [1.0, 1.05, Double.nan, Double.infinity, -1] {
            var detector = Detector()
            XCTAssertFalse(tap(&detector, 1))
            XCTAssertFalse(detector.receive(.command(.left, down: true, modifiers: [.command]), at: time))
            XCTAssertFalse(detector.receive(.command(.left, down: false, modifiers: []), at: 1.3))
        }
    }

    func testInconsistentCommandFlagsInvalidate() {
        for invalid in [Detector.Event.command(.left, down: true, modifiers: []),
                        .command(.left, down: false, modifiers: [.command]),
                        .modifiers([.command])] {
            var detector = Detector()
            XCTAssertFalse(tap(&detector, 1))
            XCTAssertFalse(detector.receive(invalid, at: 1.1))
            XCTAssertFalse(tap(&detector, 1.2))
        }
    }

    func testResetDiscardsPartialGestureAndReleaseTail() {
        for resetAfterPress in [false, true] {
            var detector = Detector()
            XCTAssertFalse(tap(&detector, 1))
            if resetAfterPress {
                XCTAssertFalse(detector.receive(.command(.left, down: true, modifiers: [.command]), at: 1.2))
            }
            detector.reset()
            XCTAssertFalse(detector.receive(.command(.left, down: false, modifiers: []), at: 1.25))
            XCTAssertFalse(tap(&detector, 1.4))
            XCTAssertTrue(tap(&detector, 1.6))
        }
    }

    func testTripleTapCannotCreateOverlappingPairs() {
        var detector = Detector()
        XCTAssertFalse(tap(&detector, 1))
        XCTAssertTrue(tap(&detector, 1.2))
        XCTAssertFalse(tap(&detector, 1.4))
        XCTAssertTrue(tap(&detector, 1.6))
    }

    func testReleaseWithoutPressNeverCounts() {
        var detector = Detector()
        XCTAssertFalse(detector.receive(.command(.left, down: false, modifiers: []), at: 1))
        XCTAssertFalse(tap(&detector, 1.2))
        XCTAssertTrue(tap(&detector, 1.4))
    }

    func testTwoCompleteNakedTapsToggleOnlyOnSecondRelease() {
        var detector = CommandDoubleTapDetector()
        XCTAssertFalse(detector.receive(.command(.left, down: true, modifiers: [.command]), at: 1))
        XCTAssertFalse(detector.receive(.command(.left, down: false, modifiers: []), at: 1.1))
        XCTAssertFalse(detector.receive(.command(.left, down: true, modifiers: [.command]), at: 1.2))
        XCTAssertTrue(detector.receive(.command(.left, down: false, modifiers: []), at: 1.3))
    }
}
