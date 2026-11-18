import Foundation
import XCTest
@testable import VoicepadCore

@MainActor
private final class PastePlatform: PasteEnvironment {
    var failure: String?
    var modifiersReleased = true
    var clipboardChangeCount = 10
    var clipboard = "original"
    var observation = PasteTextState(value: "hello", selection: NSRange(location: 5, length: 0))
    var dispatched = 0
    var restores = 0
    var snapshotFails = false
    var dispatchSucceeds = true
    var writeReturnsOriginalToken = false
    var snapshotHook: (() -> Void)?
    var writeHook: (() -> Void)?
    var waitHook: (() -> Void)?
    var dispatchHook: (() -> Void)?
    var monotonicNow: TimeInterval = 100
    var restoredAt: TimeInterval?
    var restoreSucceeds = true

    func validationFailure() -> String? { failure }
    func snapshotClipboard() throws -> PasteboardSnapshot {
        if snapshotFails { throw PasteFailure("Clipboard snapshot unavailable.") }
        let snapshot = PasteboardSnapshot(changeCount: clipboardChangeCount,
                                          items: [["text": Data(clipboard.utf8)]])
        snapshotHook?()
        return snapshot
    }
    func writeTranscript(_ text: String, replacing changeCount: Int) throws -> Int {
        guard clipboardChangeCount == changeCount else { throw PasteFailure("Clipboard changed.") }
        clipboard = text
        clipboardChangeCount += 1
        let claimed = clipboardChangeCount
        writeHook?()
        return writeReturnsOriginalToken ? claimed : clipboardChangeCount
    }
    func restoreClipboard(_ snapshot: PasteboardSnapshot, ifOwned changeCount: Int) -> Bool {
        guard clipboardChangeCount == changeCount, restoreSucceeds else { return false }
        restoredAt = monotonicNow
        clipboard = snapshot.items.first?["text"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        clipboardChangeCount += 1
        restores += 1
        return true
    }
    func observeText() -> PasteTextState? { observation }
    func dispatchPaste() -> Bool {
        guard dispatchSucceeds else { return false }
        dispatched += 1
        observation = PasteTextState(value: "hello world", selection: NSRange(location: 11, length: 0))
        dispatchHook?()
        return true
    }
    func wait(nanoseconds: UInt64) async throws {
        monotonicNow += Double(nanoseconds) / 1_000_000_000
        waitHook?()
        await Task.yield()
    }
}

final class PasteCoordinatorTests: XCTestCase {
    func testConfirmedPasteRestoresOriginalClipboard() async {
        await confirmedPaste()
    }

    func testTargetPolicyDoesNotRequireWritableSelectedText() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertNil(PasteTargetPolicy.failure(role: role))
        }
        XCTAssertNotNil(PasteTargetPolicy.failure(role: nil))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXButton"))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXSecureTextField"))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXTextField", protected: true))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXTextField", enabled: false))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXTextField", editable: false))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXWebArea"))
        XCTAssertNil(PasteTargetPolicy.failure(role: "AXWebArea", editable: true))
        XCTAssertNil(PasteTargetPolicy.failure(role: "AXWebArea", selectionEvidence: true))
        XCTAssertNotNil(PasteTargetPolicy.failure(role: "AXWebArea", editable: false, selectionEvidence: true))
    }

    func testSnapshotMaterializesEveryRepresentationAndRejectsUnsafeReads() throws {
        let items = [["text": Data("abc".utf8), "html": Data("<p>abc</p>".utf8)], ["image": Data([1, 2, 3])]]
        let types = items.map { Array($0.keys) }
        let snapshot = try PasteboardSnapshot.capture(changeCount: 3, types: types,
            read: { items[$0][$1] }, currentChangeCount: { 3 })
        XCTAssertEqual(snapshot.items, items)
        XCTAssertThrowsError(try PasteboardSnapshot.capture(changeCount: 3, types: types,
            read: { _, _ in nil }, currentChangeCount: { 3 }))
        XCTAssertThrowsError(try PasteboardSnapshot.capture(changeCount: 3, types: types,
            maximumBytes: 2, read: { items[$0][$1] }, currentChangeCount: { 3 }))
        XCTAssertThrowsError(try PasteboardSnapshot.capture(changeCount: 3, types: types,
            read: { items[$0][$1] }, currentChangeCount: { 4 }))
        let empty = try PasteboardSnapshot.capture(changeCount: 3, types: [],
            read: { _, _ in nil }, currentChangeCount: { 3 })
        XCTAssertTrue(empty.items.isEmpty)
    }

    func testBrowserValueConfirmsInsertionWithoutSelectionMetadata() {
        let before = PasteTextState(value: "Hello there", selection: nil)
        XCTAssertTrue(PasteTextState(value: "Hello wonderful there", selection: nil).confirms("wonderful ", after: before))
        XCTAssertTrue(PasteTextState(value: "Hello there", selection: nil).confirms("Hello there", after: PasteTextState(value: "", selection: nil)))
        XCTAssertFalse(PasteTextState(value: "Hello there", selection: nil).confirms("Hello", after: before))
        XCTAssertFalse(PasteTextState(value: "Hello unrelated there", selection: nil).confirms("wonderful ", after: before))
        XCTAssertFalse(PasteTextState(value: "Hello there", selection: nil).confirms("Hello there", after: PasteTextState(value: nil, selection: nil)))
    }

    func testBrowserWhitespaceNormalizationKeepsStrongBeforeAfterEvidence() {
        let before = PasteTextState(value: "", selection: NSRange(location: 0, length: 0))
        XCTAssertTrue(PasteTextState(value: "Hello\u{00a0}world\nnext", selection: nil).confirms("Hello world\r\nnext", after: before))
        XCTAssertFalse(PasteTextState(value: "Different words", selection: nil).confirms("Hello world", after: before))
    }

    func testUnconfirmedDispatchedPasteIsQuietButNotReportedAsSuccess() {
        let sent = PasteResult(dispatched: true, message: "Paste sent; not verified")
        XCTAssertFalse(sent.confirmed)
        XCTAssertFalse(sent.showTranscript)
        XCTAssertTrue(sent.showNotice)
        let blocked = PasteResult(message: "Accessibility required")
        XCTAssertTrue(blocked.showTranscript)
        XCTAssertFalse(blocked.showNotice)
        let confirmed = PasteResult(confirmed: true, dispatched: true, message: "Confirmed")
        XCTAssertFalse(confirmed.showTranscript)
        XCTAssertFalse(confirmed.showNotice)
    }

    func testUTF16ConfirmationRejectsPreexistingTextAndUnrelatedChanges() {
        let before = PasteTextState(value: "a😀z", selection: NSRange(location: 1, length: 2))
        XCTAssertTrue(PasteTextState(value: "aworldz", selection: nil).confirms("world", after: before))
        XCTAssertFalse(PasteTextState(value: "world", selection: nil).confirms("world", after: before))
        let same = PasteTextState(value: "world", selection: NSRange(location: 0, length: 5))
        XCTAssertFalse(same.confirms("world", after: same))
        let invalid = PasteTextState(value: "abc", selection: NSRange(location: NSNotFound, length: 1))
        XCTAssertFalse(same.confirms("world", after: invalid))
    }

    func testUnverifiedPasteRestoresAfterGraceWindowWithoutClaimingReceipt() async {
        await restorationWithoutReceipt()
    }

    @MainActor
    private func restorationWithoutReceipt() async {
        let unreadable = PastePlatform()
        unreadable.dispatchHook = { unreadable.observation = PasteTextState(value: nil, selection: nil) }
        let result = await PasteCoordinator().insert(" world", using: unreadable)
        XCTAssertTrue(result.dispatched)
        XCTAssertFalse(result.confirmed)
        XCTAssertEqual(unreadable.clipboard, "original")
        XCTAssertGreaterThanOrEqual(unreadable.restoredAt ?? 0, 102 - 0.000001)
        XCTAssertTrue(result.message.contains("Clipboard restored"))
        XCTAssertFalse(result.message.contains("could not confirm"))

        let changed = PastePlatform()
        changed.dispatchHook = {
            changed.observation = PasteTextState(value: nil, selection: nil)
            changed.clipboard = "new user copy"; changed.clipboardChangeCount += 1
        }
        let changedResult = await PasteCoordinator().insert(" world", using: changed)
        XCTAssertFalse(changedResult.confirmed)
        XCTAssertEqual(changed.clipboard, "new user copy")
        XCTAssertEqual(changed.restores, 0)
        XCTAssertTrue(changedResult.message.contains("newer clipboard"))

        let denied = PastePlatform()
        denied.restoreSucceeds = false
        denied.dispatchHook = { denied.observation = PasteTextState(value: nil, selection: nil) }
        let deniedResult = await PasteCoordinator().insert(" world", using: denied)
        XCTAssertEqual(denied.clipboard, " world")
        XCTAssertTrue(deniedResult.message.contains("restoration failed"))
        XCTAssertFalse(deniedResult.message.contains("Clipboard restored"))
    }

    func testCancelledDispatchedPasteWaitsBeforeRestoringOwnedClipboard() async {
        await cancelledRestoration()
    }

    @MainActor
    private func cancelledRestoration() async {
        let coordinator = PasteCoordinator()
        let platform = PastePlatform()
        platform.dispatchHook = { coordinator.cancel() }
        let result = await coordinator.insert(" world", using: platform)
        XCTAssertTrue(result.dispatched)
        XCTAssertFalse(result.confirmed)
        XCTAssertEqual(platform.clipboard, "original")
        XCTAssertGreaterThanOrEqual(platform.restoredAt ?? 0, 102 - 0.000001)
    }

    func testSafetyAndOwnership() async { await safetyAndOwnership() }
    func testConfirmationAndCancellation() async { await confirmationAndCancellation() }
    func testConcurrentInsertIsRejected() async { await concurrentInsert() }
    func testSessionGenerationAndFailureBoundaries() async { await generationAndFailures() }

    @MainActor
    private func generationAndFailures() async {
        var session = RecordingSession()
        let generation = session.begin()!
        XCTAssertTrue(session.permissionGranted(for: generation))
        XCTAssertNotNil(session.finish())
        let p = PastePlatform()
        p.snapshotHook = { session.cancel(); _ = session.begin() }
        let stale = await PasteCoordinator().insert(" world", using: p,
            isCurrent: { session.generation == generation && session.phase == .uploading })
        XCTAssertFalse(stale.dispatched)
        XCTAssertEqual(p.clipboard, "original")
        XCTAssertEqual(session.phase, .requestingPermission)

        let empty = PastePlatform()
        empty.clipboard = ""
        let emptyResult = await PasteCoordinator().insert(" world", using: empty)
        XCTAssertTrue(emptyResult.confirmed)
        XCTAssertEqual(empty.clipboard, "")

        let cannotDispatch = PastePlatform()
        cannotDispatch.dispatchSucceeds = false
        let notSent = await PasteCoordinator().insert(" world", using: cannotDispatch)
        XCTAssertFalse(notSent.dispatched)
        XCTAssertEqual(cannotDispatch.clipboard, "original")

        let released = PastePlatform()
        released.modifiersReleased = false
        released.waitHook = { released.modifiersReleased = true }
        let releaseResult = await PasteCoordinator().insert(" world", using: released)
        XCTAssertTrue(releaseResult.confirmed)

        let changedBeforeSend = PastePlatform()
        changedBeforeSend.writeHook = {
            changedBeforeSend.clipboard = "user copy"
            changedBeforeSend.clipboardChangeCount += 1
        }
        // Native adapter returns the originally claimed token, not a new owner's.
        changedBeforeSend.writeReturnsOriginalToken = true
        let changedResult = await PasteCoordinator().insert(" world", using: changedBeforeSend)
        XCTAssertFalse(changedResult.dispatched)
        XCTAssertEqual(changedBeforeSend.clipboard, "user copy")
        XCTAssertEqual(changedBeforeSend.restores, 0)

        let taskCancelled = PastePlatform()
        taskCancelled.modifiersReleased = false
        let task = Task { await PasteCoordinator().insert(" world", using: taskCancelled) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertFalse(cancelled.dispatched)
        XCTAssertEqual(taskCancelled.clipboard, "original")
    }

    @MainActor
    private func safetyAndOwnership() async {
        for reason in ["Accessibility permission is required.", "Secure field; no paste.", "No focused editable field.", "Unknown field role."] {
            let p = PastePlatform()
            p.failure = reason
            let r = await PasteCoordinator().insert(" world", using: p)
            XCTAssertFalse(r.dispatched)
            XCTAssertEqual(r.message, reason)
            XCTAssertEqual(p.clipboard, "original")
        }
        let changedTarget = PastePlatform()
        changedTarget.writeHook = { changedTarget.failure = "Focus changed." }
        let r = await PasteCoordinator().insert(" world", using: changedTarget)
        XCTAssertFalse(r.dispatched)
        XCTAssertEqual(r.message, "Focus changed.")
        XCTAssertEqual(changedTarget.clipboard, "original")

        let snapshotFailure = PastePlatform()
        snapshotFailure.snapshotFails = true
        let snapshotResult = await PasteCoordinator().insert(" world", using: snapshotFailure)
        XCTAssertFalse(snapshotResult.dispatched)
        XCTAssertEqual(snapshotFailure.clipboard, "original")

        let changedClipboard = PastePlatform()
        changedClipboard.snapshotHook = {
            changedClipboard.clipboard = "new user copy"
            changedClipboard.clipboardChangeCount += 1
        }
        let clipboardResult = await PasteCoordinator().insert(" world", using: changedClipboard)
        XCTAssertFalse(clipboardResult.dispatched)
        XCTAssertEqual(changedClipboard.clipboard, "new user copy")

        let modifiers = PastePlatform()
        modifiers.modifiersReleased = false
        let modifierResult = await PasteCoordinator().insert(" world", using: modifiers)
        XCTAssertFalse(modifierResult.dispatched)
        XCTAssertEqual(modifiers.clipboard, "original")
    }

    @MainActor
    private func confirmationAndCancellation() async {
        let uncertain = PastePlatform()
        uncertain.dispatchHook = { uncertain.observation = PasteTextState(value: nil, selection: nil) }
        let result = await PasteCoordinator().insert(" world", using: uncertain)
        XCTAssertTrue(result.dispatched)
        XCTAssertFalse(result.confirmed)
        XCTAssertFalse(result.showTranscript)
        XCTAssertTrue(result.showNotice)
        XCTAssertTrue(result.message.contains("delivery not verified"))
        XCTAssertEqual(uncertain.clipboard, "original")
        XCTAssertEqual(uncertain.restores, 1)
        XCTAssertEqual(uncertain.dispatched, 1)

        let userCopy = PastePlatform()
        userCopy.dispatchHook = { userCopy.clipboard = "user copy"; userCopy.clipboardChangeCount += 1 }
        let copyResult = await PasteCoordinator().insert(" world", using: userCopy)
        XCTAssertTrue(copyResult.confirmed)
        XCTAssertEqual(userCopy.clipboard, "user copy")
        XCTAssertEqual(userCopy.restores, 0)

        let delayed = PastePlatform()
        delayed.dispatchHook = { delayed.observation = PasteTextState(value: "hello", selection: nil) }
        delayed.waitHook = { delayed.observation = PasteTextState(value: "hello world", selection: nil) }
        let delayedResult = await PasteCoordinator().insert(" world", using: delayed)
        XCTAssertTrue(delayedResult.confirmed)

        let cancelled = PastePlatform()
        let coordinator = PasteCoordinator()
        cancelled.writeHook = { coordinator.cancel() }
        let cancelledResult = await coordinator.insert(" world", using: cancelled)
        XCTAssertFalse(cancelledResult.dispatched)
        XCTAssertEqual(cancelled.clipboard, "original")

        let afterDispatch = PastePlatform()
        afterDispatch.dispatchHook = { coordinator.cancel() }
        let after = await coordinator.insert(" world", using: afterDispatch)
        XCTAssertTrue(after.dispatched)
        XCTAssertFalse(after.confirmed)
        XCTAssertEqual(afterDispatch.clipboard, "original")

        let focusAfter = PastePlatform()
        focusAfter.dispatchHook = { focusAfter.failure = "Focus changed." }
        let focusResult = await PasteCoordinator().insert(" world", using: focusAfter)
        XCTAssertTrue(focusResult.dispatched)
        XCTAssertFalse(focusResult.confirmed)
        XCTAssertEqual(focusAfter.restores, 1)
    }

    @MainActor
    private func concurrentInsert() async {
        let coordinator = PasteCoordinator()
        let p = PastePlatform()
        p.modifiersReleased = false
        var waiting = false
        p.waitHook = { waiting = true }
        let first = Task { await coordinator.insert(" world", using: p) }
        while !waiting { await Task.yield() }
        let second = await coordinator.insert("second", using: PastePlatform())
        XCTAssertFalse(second.dispatched)
        XCTAssertTrue(second.message.contains("in progress"))
        coordinator.cancel()
        _ = await first.value
        XCTAssertEqual(p.dispatched, 0)
    }

    @MainActor
    private func confirmedPaste() async {
        let platform = PastePlatform()
        let result = await PasteCoordinator().insert(" world", using: platform)
        XCTAssertTrue(result.confirmed)
        XCTAssertTrue(result.dispatched)
        XCTAssertFalse(result.showTranscript)
        XCTAssertEqual(platform.dispatched, 1)
        XCTAssertEqual(platform.restores, 1)
        XCTAssertEqual(platform.clipboard, "original")
    }
}
