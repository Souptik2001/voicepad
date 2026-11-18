/// Recognizes two complete, naked taps of the same physical Command key.
public struct CommandDoubleTapDetector: Sendable {
    public enum Key: Sendable { case left, right }
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Self(rawValue: 1)
        public static let capsLock = Self(rawValue: 2)
        public static let other = Self(rawValue: 4)
    }
    public enum Event: Sendable {
        case command(Key, down: Bool, modifiers: Modifiers)
        case modifiers(Modifiers)
        case interruption
    }
    /// Each hold is at most 300ms; first release → second press at most 350ms.
    public static let maximumHold = 0.3
    public static let maximumGap = 0.35
    private var pressed: (key: Key, time: Double)?
    private var first: (key: Key, time: Double)?
    private var lastTime: Double?
    public init() {}
    public mutating func reset() { pressed = nil; first = nil; lastTime = nil }

    public mutating func receive(_ event: Event, at time: Double) -> Bool {
        guard time.isFinite, time >= 0, lastTime.map({ time > $0 }) ?? true else {
            pressed = nil
            first = nil
            return false
        }
        lastTime = time
        switch event {
        case .interruption:
            pressed = nil
            first = nil
        case .modifiers(let flags):
            let expected: Modifiers = pressed == nil ? [] : [.command]
            if flags.subtracting(.capsLock) != expected {
                pressed = nil
                first = nil
            }
        case let .command(key, down, flags):
            let expected: Modifiers = down ? [.command] : []
            guard flags.subtracting(.capsLock) == expected else {
                pressed = nil
                first = nil
                return false
            }
            if down {
                guard pressed == nil else {
                    pressed = nil
                    first = nil
                    return false
                }
                if let first {
                    guard first.key == key else {
                        self.first = nil
                        return false // Do not recycle a mismatched press.
                    }
                    if time - first.time > Self.maximumGap + 1e-9 { self.first = nil }
                }
                pressed = (key, time)
            } else {
                guard let pressed, pressed.key == key,
                      time - pressed.time <= Self.maximumHold + 1e-9 else {
                    self.pressed = nil
                    first = nil
                    return false
                }
                self.pressed = nil
                if first != nil {
                    first = nil // Consume both taps; never overlap triple taps.
                    return true
                }
                first = (key, time)
            }
        }
        return false
    }
}
