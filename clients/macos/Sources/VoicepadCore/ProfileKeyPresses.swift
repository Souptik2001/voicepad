/// Tracks only handled physical presses, never typed text. Prevents repeated
/// selection and consumes the matching key-up only when key-down was handled.
public struct ProfileKeyPresses: Sendable {
    private var consumed = Set<Int>()
    public init() {}
    public mutating func reset() { consumed.removeAll() }

    public mutating func consume(key: Int, down: Bool, handle: () -> Bool) -> Bool {
        if !down { return consumed.remove(key) != nil }
        if consumed.contains(key) { return true }
        guard handle() else { return false }
        consumed.insert(key)
        return true
    }
}
