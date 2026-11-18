import Foundation

public struct VoicepadProfile: Codable, Equatable, Sendable {
    public let slot: Int
    public let name: String
    public let instructions: String

    public static func validated(_ profiles: [VoicepadProfile]) throws -> [VoicepadProfile] {
        guard profiles.count <= 9, Set(profiles.map(\.slot)).count == profiles.count,
              profiles.allSatisfy({ (1...9).contains($0.slot) }) else { throw VoicepadError.invalidResponse }
        return profiles.sorted { $0.slot < $1.slot }
    }

    public init(slot: Int, name: String, instructions: String) {
        self.slot = slot
        self.name = name
        self.instructions = instructions
    }
}

/// Main-actor-owned value state. Only a fresh load for this listening attempt
/// may enable custom slots. Stop freezes the outgoing choice, including nil.
public struct ProfileSelection: Sendable {
    public private(set) var profiles: [VoicepadProfile] = []
    public private(set) var selectedSlot: Int?
    public private(set) var savedSlot: Int?
    public private(set) var uploadSlot: Int?
    public private(set) var loading = false
    public private(set) var unavailable = false
    private var generation = 0
    private var listening = false

    public init(savedSlot: Int? = nil) {
        self.savedSlot = savedSlot.flatMap { (1...9).contains($0) ? $0 : nil }
    }

    @discardableResult
    public mutating func begin() -> Int {
        generation += 1
        listening = true
        profiles = []
        selectedSlot = nil
        uploadSlot = nil
        loading = true
        unavailable = false
        return generation
    }

    @discardableResult
    public mutating func loaded(_ profiles: [VoicepadProfile], for token: Int) throws -> Bool {
        guard token == generation, listening, loading else { return false }
        self.profiles = try VoicepadProfile.validated(profiles)
        loading = false
        selectedSlot = savedSlot.flatMap { slot in self.profiles.contains { $0.slot == slot } ? slot : nil }
        savedSlot = selectedSlot
        return true
    }

    @discardableResult
    public mutating func select(_ slot: Int) -> Bool {
        guard listening, slot == 0 || profiles.contains(where: { $0.slot == slot }) else { return false }
        selectedSlot = slot == 0 ? nil : slot
        savedSlot = selectedSlot
        return true
    }

    public struct Chip: Equatable, Sendable {
        public let slot: Int
        public let title: String
        public let selected: Bool
    }

    public var chips: [Chip] {
        [Chip(slot: 0, title: "0  Raw", selected: selectedSlot == nil)] + profiles.map {
            let clean = $0.name.components(separatedBy: .controlCharacters).joined(separator: " ")
            return Chip(slot: $0.slot, title: "\($0.slot)  " + String(clean.prefix(40)), selected: selectedSlot == $0.slot)
        }
    }

    public var hudStatus: String {
        if loading { return "Loading profiles · raw until ready" }
        if unavailable { return "Profiles unavailable · using raw" }
        return "Selected at stop · 0 for raw"
    }

    /// Physical ANSI digits (and keypad digits); never interpret arbitrary typed text.
    public func slotForKey(keyCode: Int, modified: Bool) -> Int? {
        guard listening, !modified else { return nil }
        let digits = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                      82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
        guard let slot = digits[keyCode], slot == 0 || profiles.contains(where: { $0.slot == slot }) else { return nil }
        return slot
    }

    @discardableResult
    public mutating func failed(for token: Int) -> Bool {
        guard generation == token, listening, loading else { return false }
        profiles = []
        savedSlot = nil
        selectedSlot = nil
        loading = false
        unavailable = true
        return true
    }

    public mutating func cancel() {
        generation += 1
        listening = false
        profiles = []
        selectedSlot = nil
        uploadSlot = nil
        loading = false
    }

    @discardableResult
    public mutating func stop() -> Int? {
        if loading { savedSlot = nil }
        uploadSlot = selectedSlot
        listening = false
        return uploadSlot
    }
}
