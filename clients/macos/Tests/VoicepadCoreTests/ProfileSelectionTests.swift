import XCTest
@testable import VoicepadCore

final class ProfileSelectionTests: XCTestCase {
    func testHandledPressConsumesRepeatAndReleaseButNothingElse() {
        var keys = ProfileKeyPresses()
        var callbacks = 0
        XCTAssertTrue(keys.consume(key: 18, down: true) { callbacks += 1; return true })
        XCTAssertTrue(keys.consume(key: 18, down: true) { XCTFail("Repeat must not select again"); return false })
        XCTAssertTrue(keys.consume(key: 18, down: false) { XCTFail("Release must not select"); return false })
        XCTAssertFalse(keys.consume(key: 18, down: false) { XCTFail("Unhandled release"); return true })
        XCTAssertFalse(keys.consume(key: 19, down: true) { callbacks += 1; return false })
        XCTAssertFalse(keys.consume(key: 19, down: false) { XCTFail("Unhandled release"); return true })
        XCTAssertEqual(callbacks, 2)
        XCTAssertTrue(keys.consume(key: 18, down: true) { true })
        keys.reset()
        XCTAssertFalse(keys.consume(key: 18, down: false) { false })
    }

    private let official = VoicepadProfile(slot: 1, name: "Official", instructions: "Be formal")

    func testFailureClearsSavedIDsAndDisablesCustomSelection() throws {
        var state = ProfileSelection(savedSlot: 1)
        let token = state.begin()
        XCTAssertTrue(state.failed(for: token))
        XCTAssertTrue(state.unavailable)
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.savedSlot)
        XCTAssertFalse(state.select(1))
        XCTAssertTrue(state.select(0))
        XCTAssertNil(state.stop())
    }

    func testStaleLoadAndFailureCannotMutateNewAttemptOrStoppedChoice() throws {
        var state = ProfileSelection(savedSlot: 1)
        let old = state.begin()
        let current = state.begin()
        XCTAssertFalse(try state.loaded([official], for: old))
        XCTAssertFalse(state.failed(for: old))
        XCTAssertTrue(try state.loaded([official], for: current))
        XCTAssertFalse(state.select(9))
        XCTAssertTrue(state.select(1))
        XCTAssertEqual(state.stop(), 1)
        XCTAssertFalse(state.failed(for: current))
        XCTAssertEqual(state.uploadSlot, 1)
        XCTAssertFalse(try state.loaded([], for: current))
        XCTAssertEqual(state.uploadSlot, 1)
    }

    func testExplicitRawWhileLoadingCannotBeOverwrittenByLoad() throws {
        var state = ProfileSelection(savedSlot: 1)
        let token = state.begin()
        XCTAssertTrue(state.select(0))
        XCTAssertTrue(try state.loaded([official], for: token))
        XCTAssertNil(state.selectedSlot)
        XCTAssertNil(state.savedSlot)
    }

    func testCancelInvalidatesPendingLoadAndClearsVisibleSelection() throws {
        var state = ProfileSelection(savedSlot: 1)
        let token = state.begin()
        state.cancel()
        XCTAssertFalse(try state.loaded([official], for: token))
        XCTAssertFalse(state.select(0))
        XCTAssertFalse(state.failed(for: token))
        XCTAssertTrue(state.profiles.isEmpty)
    }

    func testStopBeforeLoadUsesRawAndClearsUnvalidatedPreference() throws {
        var state = ProfileSelection(savedSlot: 1)
        let token = state.begin()
        XCTAssertNil(state.stop())
        XCTAssertNil(state.savedSlot)
        XCTAssertFalse(try state.loaded([official], for: token))
    }

    func testCatalogValidatesUniqueFixedSlotsAndSortsWithoutRenumbering() throws {
        for invalid in [[VoicepadProfile(slot: 0, name: "Bad", instructions: "")],
                        [VoicepadProfile(slot: 10, name: "Bad", instructions: "")], [official, official]] {
            var state = ProfileSelection()
            let token = state.begin()
            XCTAssertThrowsError(try state.loaded(invalid, for: token))
        }
        var state = ProfileSelection(savedSlot: 8)
        let token = state.begin()
        XCTAssertTrue(try state.loaded([VoicepadProfile(slot: 9, name: "Nine", instructions: ""), official], for: token))
        XCTAssertEqual(state.profiles.map(\.slot), [1, 9])
        XCTAssertNil(state.savedSlot)
        XCTAssertTrue(state.select(9)) // Empty instructions are still a valid raw server profile.
        XCTAssertTrue(state.select(0))
        XCTAssertNil(state.selectedSlot)
        XCTAssertFalse(state.select(-1))
    }

    func testPhysicalDigitsOnlyHandleUnmodifiedPopulatedSlotsWhileListening() throws {
        var state = ProfileSelection()
        let token = state.begin()
        XCTAssertNil(state.slotForKey(keyCode: 18, modified: false))
        XCTAssertEqual(state.slotForKey(keyCode: 29, modified: false), 0)
        XCTAssertTrue(try state.loaded([official], for: token))
        XCTAssertEqual(state.slotForKey(keyCode: 18, modified: false), 1)
        XCTAssertNil(state.slotForKey(keyCode: 19, modified: false))
        XCTAssertNil(state.slotForKey(keyCode: 18, modified: true))
        XCTAssertNil(state.slotForKey(keyCode: 53, modified: false))
        _ = state.stop()
        XCTAssertNil(state.slotForKey(keyCode: 18, modified: false))
    }
    func testSavedSelectionRequiresFreshValidationAndStopFreezesSlot() throws {
        var state = ProfileSelection(savedSlot: 9)
        let token = state.begin()
        XCTAssertNil(state.selectedSlot)
        XCTAssertNil(state.uploadSlot)
        XCTAssertTrue(try state.loaded([VoicepadProfile(slot: 9, name: "Official", instructions: "Be formal")], for: token))
        XCTAssertEqual(state.selectedSlot, 9)
        XCTAssertEqual(state.savedSlot, 9)
        XCTAssertEqual(state.stop(), 9)
        XCTAssertFalse(state.select(0))
        XCTAssertFalse(try state.loaded([], for: token))
    }
}
