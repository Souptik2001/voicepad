import XCTest
@testable import VoicepadCore

final class ShortcutModeTests: XCTestCase {
    func testPersistentValuesDoNotChange() {
        XCTAssertEqual(ShortcutMode.controlOptionSpace.rawValue, 0)
        XCTAssertEqual(ShortcutMode.controlShiftSpace.rawValue, 1)
        XCTAssertEqual(ShortcutMode.doubleCommand.rawValue, 2)
    }

    func testNewAndOldDefaultInstallationsChooseDoubleCommand() {
        XCTAssertEqual(ShortcutMode.initial(saved: nil, version: 0), .doubleCommand)
        XCTAssertEqual(ShortcutMode.initial(saved: 0, version: 0), .doubleCommand)
        XCTAssertEqual(ShortcutMode.initial(saved: 1, version: 0), .controlShiftSpace)
        XCTAssertEqual(ShortcutMode.initial(saved: 2, version: 0), .doubleCommand)
    }

    func testExplicitChoicesSurviveAfterMigration() {
        for mode in ShortcutMode.allCases {
            XCTAssertEqual(ShortcutMode.initial(saved: mode.rawValue, version: 1), mode)
            XCTAssertEqual(ShortcutMode.initial(saved: mode.rawValue, version: 2), mode)
        }
    }

    func testAbsentOrInvalidPreferencesHaveSafeDefault() {
        XCTAssertEqual(ShortcutMode.initial(saved: nil, version: 1), .doubleCommand)
        XCTAssertEqual(ShortcutMode.initial(saved: -1, version: 1), .doubleCommand)
        XCTAssertEqual(ShortcutMode.initial(saved: 999, version: 0), .doubleCommand)
    }
}
