import Foundation

public struct PasteFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// In-memory, concrete representations only. Never persisted to disk.
public struct PasteboardSnapshot {
    public let changeCount: Int
    public let items: [[String: Data]]
    public init(changeCount: Int, items: [[String: Data]]) {
        self.changeCount = changeCount
        self.items = items
    }
}

public extension PasteboardSnapshot {
    static func capture(changeCount: Int, types: [[String]], maximumBytes: Int = 16 * 1024 * 1024,
                        read: (Int, String) -> Data?, currentChangeCount: () -> Int) throws -> PasteboardSnapshot {
        var items: [[String: Data]] = []
        var remaining = maximumBytes
        // Bound metadata as well as data; pathological pasteboards fail closed.
        guard types.count <= 1024 else { throw PasteFailure("Clipboard snapshot unavailable: too many items. Use Copy Last Transcript.") }
        for (index, representations) in types.enumerated() {
            guard !representations.isEmpty, representations.count <= 1024 else {
                throw PasteFailure("Clipboard snapshot unavailable: unsupported item. Use Copy Last Transcript.")
            }
            var item: [String: Data] = [:]
            for type in representations {
                guard currentChangeCount() == changeCount else {
                    throw PasteFailure("Clipboard changed while being saved. Paste not requested.")
                }
                guard let data = read(index, type), data.count <= remaining else {
                    throw PasteFailure("Clipboard snapshot unavailable: unreadable or larger than 16 MB. Use Copy Last Transcript.")
                }
                remaining -= data.count
                item[type] = data
            }
            items.append(item)
        }
        guard currentChangeCount() == changeCount else {
            throw PasteFailure("Clipboard changed while being saved. Paste not requested.")
        }
        return PasteboardSnapshot(changeCount: changeCount, items: items)
    }
}

public enum PasteTargetPolicy {
    public static func failure(role: String?, subrole: String = "", protected: Bool = false,
                               enabled: Bool? = nil, editable: Bool? = nil,
                               selectionEvidence: Bool = false) -> String? {
        let identity = ((role ?? "") + subrole).lowercased()
        if protected || identity.contains("secure") || identity.contains("password") {
            return "Protected or password field. Paste not requested; use Copy Last Transcript only in a safe field."
        }
        guard let role else { return "Focused field role is unknown. Paste not requested; use Copy Last Transcript." }
        if enabled == false || editable == false {
            return "Focused field is disabled or read-only. Paste not requested; use Copy Last Transcript."
        }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox": return nil
        case "AXWebArea" where editable == true || selectionEvidence: return nil
        default: return "No known focused editable field. Paste not requested; use Copy Last Transcript."
        }
    }
}

public struct PasteTextState {
    public let value: String?
    public let selection: NSRange?
    public init(value: String?, selection: NSRange?) {
        self.value = value
        self.selection = selection
    }

    /// AX ranges use UTF-16 offsets, not Swift Character offsets.
    public func confirms(_ text: String, after before: PasteTextState) -> Bool {
        guard let old = before.value, let value, value != old, !text.isEmpty else { return false }
        if let range = before.selection {
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
                  range.location <= (old as NSString).length,
                  range.length <= (old as NSString).length - range.location else { return false }
            let expected = (old as NSString).replacingCharacters(in: range, with: text)
            return Self.normalized(value) != Self.normalized(old)
                && Self.normalized(value) == Self.normalized(expected)
        }
        // Some web editors expose their value but not the selected-text range.
        // Accept only a single pure insertion of exactly the transcript. Never
        // treat a substring already present, a replacement, or unrelated edits as receipt.
        let original = Array(Self.normalized(old))
        let actual = Array(Self.normalized(value))
        let insertion = Array(Self.normalized(text))
        guard !insertion.isEmpty, actual.count == original.count + insertion.count else { return false }
        var prefix = 0
        while prefix < original.count && original[prefix] == actual[prefix] { prefix += 1 }
        // Linear-time before/after evidence; do not scan every possible caret.
        return actual[prefix..<(prefix + insertion.count)].elementsEqual(insertion)
            && actual[(prefix + insertion.count)...].elementsEqual(original[prefix...])
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .precomposedStringWithCanonicalMapping
    }

}

public struct PasteResult {
    public let confirmed: Bool
    public let dispatched: Bool
    public let message: String
    public let clipboardRestored: Bool
    /// A dispatched but unverified paste should not interrupt successful typing.
    /// Keep its transcript in the menu and show only a brief neutral notice.
    public var showTranscript: Bool { !dispatched }
    public var showNotice: Bool { dispatched && !confirmed }
    public init(confirmed: Bool = false, dispatched: Bool = false, message: String, clipboardRestored: Bool = false) {
        self.confirmed = confirmed
        self.dispatched = dispatched
        self.message = message
        self.clipboardRestored = clipboardRestored
    }
}

/// Native operations are synchronous on MainActor; the coordinator owns all waits.
/// write/restore must guard ownership immediately before mutating the pasteboard.
@MainActor
public protocol PasteEnvironment: AnyObject {
    func validationFailure() -> String?
    var modifiersReleased: Bool { get }
    var clipboardChangeCount: Int { get }
    func snapshotClipboard() throws -> PasteboardSnapshot
    func writeTranscript(_ text: String, replacing changeCount: Int) throws -> Int
    func restoreClipboard(_ snapshot: PasteboardSnapshot, ifOwned changeCount: Int) -> Bool
    func observeText() -> PasteTextState?
    /// false means no event was dispatched; true is NOT a receipt.
    func dispatchPaste() -> Bool
    var monotonicNow: TimeInterval { get }
    func wait(nanoseconds: UInt64) async throws
}

public extension PasteEnvironment {
    var monotonicNow: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
public final class PasteCoordinator {
    private var busy = false
    private var generation = 0
    private var cleanup: (() -> Void)?
    public init() {}

    /// Synchronous cleanup is also used at application termination, when an
    /// async task may never get another run-loop turn. Never undo a sent paste.
    public func cancel() {
        generation += 1
        cleanup?()
        cleanup = nil
    }

    public func insert(_ text: String, using environment: PasteEnvironment,
                       isCurrent: () -> Bool = { true }) async -> PasteResult {
        guard !busy else { return PasteResult(message: "A paste is already in progress. Use Copy Last Transcript.") }
        busy = true
        let attempt = generation
        var dispatched = false
        var owned: Int?
        var snapshot: PasteboardSnapshot?
        var restoreDeadline: TimeInterval?
        defer {
            cleanup?()
            cleanup = nil
            busy = false
        }
        func check() throws {
            guard !Task.isCancelled, attempt == generation, isCurrent() else {
                throw PasteFailure("Paste cancelled before dispatch. Use Copy Last Transcript.")
            }
            if let reason = environment.validationFailure() { throw PasteFailure(reason) }
        }
        func unconfirmed() async -> PasteResult {
            // Delivery confirmation and temporary clipboard lifetime are separate.
            // Give a slow receiver time to read before restoring our own clipboard.
            if let deadline = restoreDeadline {
                while environment.monotonicNow < deadline,
                      owned == environment.clipboardChangeCount {
                    let remaining = min(0.1, deadline - environment.monotonicNow)
                    do {
                        try await environment.wait(nanoseconds: max(1, UInt64(max(0, remaining) * 1_000_000_000)))
                    } catch {
                        // Cancellation must not restore too early or skip cleanup.
                        let rest = max(0, deadline - environment.monotonicNow)
                        await Task.detached {
                            try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
                        }.value
                        break
                    }
                }
            }
            guard let snapshot, let owned else {
                return PasteResult(dispatched: true, message: "Paste sent; delivery not verified. Recovery text is in the VP menu.")
            }
            let stillOwned = owned == environment.clipboardChangeCount
            let restored = stillOwned && environment.restoreClipboard(snapshot, ifOwned: owned)
            let clipboardStatus = restored ? "Clipboard restored."
                : stillOwned ? "Clipboard restoration failed; use the VP menu for recovery."
                : "Your newer clipboard was kept."
            return PasteResult(dispatched: true,
                message: "Paste sent; delivery not verified. \(clipboardStatus) Check the field before pasting again; recovery text is in the VP menu.",
                clipboardRestored: restored)
        }
        do {
            guard !text.isEmpty else { return PasteResult(message: "No text to paste.") }
            try check()
            // Allow the last hotkey release to reach the hardware state. Never
            // synthesize modifier releases: that would interfere with typing.
            for _ in 0..<15 {
                if environment.modifiersReleased { break }
                try await environment.wait(nanoseconds: 20_000_000)
                try check()
            }
            guard environment.modifiersReleased else {
                throw PasteFailure("Paste not requested: release Command, Control, Option and Shift. Use Copy Last Transcript.")
            }
            let saved = try environment.snapshotClipboard()
            snapshot = saved
            try check()
            guard environment.clipboardChangeCount == saved.changeCount else {
                throw PasteFailure("Clipboard changed while being saved. Paste not requested; use Copy Last Transcript.")
            }
            let before = environment.observeText()
            try check()
            let token = try environment.writeTranscript(text, replacing: saved.changeCount)
            owned = token
            cleanup = { _ = environment.restoreClipboard(saved, ifOwned: token) }
            try check()
            guard environment.clipboardChangeCount == token else {
                throw PasteFailure("Clipboard changed before paste. Paste not requested; use Copy Last Transcript.")
            }
            guard environment.modifiersReleased else {
                throw PasteFailure("Modifier key held. Paste not requested; use Copy Last Transcript.")
            }
            // No await between final target validation and the dispatch.
            try check()
            // Treat the entire dispatch call as potentially delivered, including
            // synchronous cancellation callbacks inside a native adapter.
            cleanup = nil
            guard environment.dispatchPaste() else {
                throw PasteFailure("Paste could not be requested. Use Copy Last Transcript.")
            }
            dispatched = true
            cleanup = nil // Posting events is not proof of delivery or failure.
            let confirmationDeadline = environment.monotonicNow + 2
            restoreDeadline = confirmationDeadline
            for poll in 0...20 {
                guard environment.monotonicNow < confirmationDeadline,
                      !Task.isCancelled, generation == attempt, isCurrent(),
                      environment.validationFailure() == nil else { return await unconfirmed() }
                if let before, let after = environment.observeText(), after.confirms(text, after: before),
                   environment.validationFailure() == nil, !Task.isCancelled,
                   generation == attempt, isCurrent() {
                    let restored = environment.restoreClipboard(saved, ifOwned: token)
                    return PasteResult(confirmed: true, dispatched: true,
                        message: restored ? "Paste confirmed in the original field. Clipboard restored."
                            : "Paste confirmed in the original field. Clipboard restoration was not confirmed; a newer copy is never intentionally replaced.",
                        clipboardRestored: restored)
                }
                if poll < 20 { try await environment.wait(nanoseconds: 100_000_000) }
            }
            return await unconfirmed()
        } catch {
            if dispatched { return await unconfirmed() }
            // Also covers cancellation inside an injected clipboard write.
            if cleanup == nil, let snapshot, let owned {
                _ = environment.restoreClipboard(snapshot, ifOwned: owned)
            }
            return PasteResult(message: error.localizedDescription)
        }
    }
}
