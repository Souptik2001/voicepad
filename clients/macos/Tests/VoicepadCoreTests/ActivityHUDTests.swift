import Foundation
import XCTest
@testable import VoicepadCore

final class ActivityHUDTests: XCTestCase {
    func testChipContentHasSymmetricRealInsetsAndNonnegativeSmallBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 78, height: 32)
        let content = ActivityHUDLayout.profileChipContentRect(in: bounds)
        XCTAssertEqual(content, CGRect(x: 8, y: 6, width: 62, height: 20))
        XCTAssertEqual(content.minX - bounds.minX, bounds.maxX - content.maxX)
        XCTAssertEqual(content.minY - bounds.minY, bounds.maxY - content.maxY)
        let tiny = ActivityHUDLayout.profileChipContentRect(in: CGRect(x: 2, y: 3, width: 6, height: 4))
        XCTAssertEqual(tiny.width, 0)
        XCTAssertEqual(tiny.height, 0)
        XCTAssertEqual(ActivityHUDLayout.cardHeight(profileRows: 4), 282)
        XCTAssertEqual(ActivityHUDLayout.cardHeight(profileRows: 1), 174)
        XCTAssertEqual(ActivityHUDLayout.cardHeight(profileRows: 0), 116)
    }

    func testProfileCardExpandsWithinScreenAndChipsKeepFixedNumbers() throws {
        let visible = CGRect(x: -1200, y: 50, width: 1000, height: 700)
        let frame = ActivityHUDLayout.frame(in: visible, profileRows: 4)
        XCTAssertEqual(frame.width, 272)
        XCTAssertEqual(frame.height, 282)
        XCTAssertTrue(visible.contains(frame))
        let tiny = CGRect(x: 0, y: 0, width: 160, height: 100)
        XCTAssertTrue(tiny.contains(ActivityHUDLayout.frame(in: tiny, profileRows: 4)))
        var state = ProfileSelection(savedSlot: 9)
        let token = state.begin()
        XCTAssertEqual(state.hudStatus, "Loading profiles · raw until ready")
        XCTAssertTrue(try state.loaded([VoicepadProfile(slot: 9, name: "Official", instructions: "")], for: token))
        XCTAssertEqual(state.chips.map(\.title), ["0  Raw", "9  Official"])
        XCTAssertEqual(state.chips.map(\.selected), [false, true])
        // AppKit chip buttons use explicit content insets; the border must not hug the label.
        XCTAssertGreaterThan(ActivityHUDLayout.profileChipHorizontalPadding, 0)
        XCTAssertGreaterThan(ActivityHUDLayout.profileChipVerticalPadding, 0)
        XCTAssertEqual(state.hudStatus, "Selected at stop · 0 for raw")
        XCTAssertTrue(state.select(0))
        XCTAssertTrue(state.chips[0].selected)
        let failed = state.begin()
        XCTAssertTrue(state.failed(for: failed))
        XCTAssertEqual(state.hudStatus, "Profiles unavailable · using raw")
    }

    func testCompactHUDSitsOnLeftInsideVisibleDesktop() {
        let visible = CGRect(x: 0, y: 50, width: 1440, height: 830)
        let frame = ActivityHUDLayout.frame(in: visible)
        XCTAssertEqual(frame.width, 272)
        XCTAssertEqual(frame.height, 116)
        XCTAssertEqual(frame.minX, visible.minX + 20)
        XCTAssertEqual(frame.midY, visible.midY)
        XCTAssertTrue(visible.contains(frame))
    }

    func testNegativeOriginAndSmallScreensAreClamped() {
        let secondary = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        XCTAssertTrue(secondary.contains(ActivityHUDLayout.frame(in: secondary)))
        let small = CGRect(x: 500, y: 20, width: 200, height: 90)
        let compact = ActivityHUDLayout.frame(in: small)
        XCTAssertTrue(small.contains(compact))
        XCTAssertEqual(compact.width / compact.height, 272.0 / 116.0, accuracy: 0.0001)
    }

    func testRecordingHasRealTimerAndMinimalInstruction() {
        let state = ActivityHUDContent(title: "Recording", detail: "anything", elapsed: 65.9)
        XCTAssertEqual(state.heading, "Listening")
        XCTAssertEqual(state.time, "01:05")
        XCTAssertTrue(state.recording)
        XCTAssertFalse(state.processing)
        XCTAssertEqual(state.subtitle, "anything")
    }

    func testProcessingAndNoticeDoNotPretendToRecord() {
        let state = ActivityHUDContent(title: "Transcribing", detail: "Sending audio", elapsed: 2)
        XCTAssertFalse(state.recording)
        XCTAssertTrue(state.processing)
        XCTAssertEqual(state.heading, "Finding your words")
        XCTAssertEqual(ActivityHUDContent(title: "Pasting", detail: "Checking").heading, "Placing your words")
        let notice = ActivityHUDContent(title: "Paste sent", detail: "Delivery not verified")
        XCTAssertFalse(notice.recording)
        XCTAssertFalse(notice.processing)
        XCTAssertNil(notice.time)
        XCTAssertEqual(notice.subtitle, "Delivery not verified")
    }

    func testInvalidTimerDoesNotExposeNanOrNegativeTime() {
        XCTAssertNil(ActivityHUDContent(title: "Recording", detail: "", elapsed: .nan).time)
        XCTAssertNil(ActivityHUDContent(title: "Recording", detail: "", elapsed: -.infinity).time)
        XCTAssertEqual(ActivityHUDContent(title: "Recording", detail: "", elapsed: -10).time, "00:00")
    }
}
