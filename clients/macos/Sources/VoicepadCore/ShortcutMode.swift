/// Persistent shortcut identifiers. Never renumber existing hold modes.
public enum ShortcutMode: Int, CaseIterable, Sendable {
    case controlOptionSpace = 0
    case controlShiftSpace = 1
    case doubleCommand = 2

    /// Version 0 always saved the old default, even without an explicit choice.
    /// Migrate that default once, preserving the alternative and later choices.
    public static func initial(saved: Int?, version: Int) -> Self {
        if version < 1, saved == nil || saved == 0 { return .doubleCommand }
        return saved.flatMap(Self.init(rawValue:)) ?? .doubleCommand
    }
}
