import XCTest
@testable import VoicepadCore

final class RecordingLimitsTests: XCTestCase {
    func testTenMinuteBoundaryAndEncoderAllowance() {
        XCTAssertEqual(RecordingLimits.maximumSeconds, 600)
        XCTAssertTrue(RecordingLimits.acceptsDuration(600))
        XCTAssertTrue(RecordingLimits.acceptsDuration(600.nextDown))
        XCTAssertFalse(RecordingLimits.acceptsDuration(600.nextUp))
        XCTAssertFalse(RecordingLimits.acceptsDuration(.infinity))
        XCTAssertFalse(RecordingLimits.acceptsDuration(.nan))
        XCTAssertEqual(RecordingLimits.captureSeconds, 599.8, accuracy: 0.000_001)
        XCTAssertTrue(RecordingLimits.acceptsDuration(RecordingLimits.captureSeconds + 0.2))
    }
}
