import XCTest
@testable import VoicepadCore

final class RecordingSessionTests: XCTestCase {
    func testToggleActionForEveryPhase() {
        XCTAssertEqual(SessionPhase.idle.toggleAction, .begin)
        XCTAssertEqual(SessionPhase.requestingPermission.toggleAction, .cancel)
        XCTAssertEqual(SessionPhase.recording.toggleAction, .finish)
        XCTAssertEqual(SessionPhase.uploading.toggleAction, .ignore)
    }

    func testCompletionRequiresCurrentUploadingGeneration() {
        var session = RecordingSession()
        let token = session.begin()!
        XCTAssertFalse(session.complete(for: token))
        XCTAssertTrue(session.permissionGranted(for: token))
        XCTAssertFalse(session.complete(for: token))
        XCTAssertEqual(session.finish(), token)
        XCTAssertFalse(session.complete(for: token + 1))
        XCTAssertEqual(session.phase, .uploading)
        XCTAssertTrue(session.complete(for: token))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.complete(for: token))
    }

    func testCancelInvalidatesEveryPhaseAndStaleCompletionCannotEndNewSession() {
        for phase in [SessionPhase.idle, .requestingPermission, .recording, .uploading] {
            var session = RecordingSession()
            if phase != .idle { session.begin() }
            if phase == .recording || phase == .uploading {
                XCTAssertTrue(session.permissionGranted(for: session.generation))
            }
            if phase == .uploading { _ = session.finish() }
            let oldToken = session.generation
            session.cancel()
            XCTAssertEqual(session.phase, .idle)
            XCTAssertGreaterThan(session.generation, oldToken)
            let newToken = session.begin()!
            XCTAssertFalse(session.permissionGranted(for: oldToken))
            XCTAssertTrue(session.permissionGranted(for: newToken))
            XCTAssertEqual(session.finish(), newToken)
            XCTAssertFalse(session.complete(for: oldToken))
            XCTAssertEqual(session.phase, .uploading)
            XCTAssertTrue(session.complete(for: newToken))
        }
    }

    func testEarlyReleaseInvalidatesPendingPermission() {
        var session = RecordingSession()
        let token = session.begin()!
        XCTAssertNil(session.finish())
        XCTAssertEqual(session.phase, .idle)
        XCTAssertGreaterThan(session.generation, token)
        XCTAssertFalse(session.permissionGranted(for: token))
        XCTAssertNil(session.finish())
    }

    func testFinishUploadsOnlyOnce() {
        var session = RecordingSession()
        let token = session.begin()!
        XCTAssertTrue(session.permissionGranted(for: token))
        XCTAssertEqual(session.finish(), token)
        XCTAssertEqual(session.phase, .uploading)
        XCTAssertNil(session.finish())
        XCTAssertNil(session.begin())
    }

    func testMatchingPermissionTransitionsToRecordingOnlyOnce() {
        var session = RecordingSession()
        let token = session.begin()!
        XCTAssertFalse(session.permissionGranted(for: token + 1))
        XCTAssertEqual(session.phase, .requestingPermission)
        XCTAssertTrue(session.permissionGranted(for: token))
        XCTAssertEqual(session.phase, .recording)
        XCTAssertFalse(session.permissionGranted(for: token))
        XCTAssertNil(session.begin())
    }

    func testBeginStartsPermissionRequestAndRejectsDoubleStart() {
        var session = RecordingSession()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(session.begin(), 1)
        XCTAssertEqual(session.phase, .requestingPermission)
        XCTAssertNil(session.begin())
        XCTAssertEqual(session.generation, 1)
    }
}
