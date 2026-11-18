/// A single recording attempt, including permission and upload work.
public enum SessionPhase: Equatable, Sendable {
    case idle, requestingPermission, recording, uploading

    public enum ToggleAction: Equatable, Sendable { case begin, cancel, finish, ignore }
    public var toggleAction: ToggleAction {
        switch self {
        case .idle: return .begin
        case .requestingPermission: return .cancel
        case .recording: return .finish
        case .uploading: return .ignore
        }
    }
}

/// Value-type state machine. Keep mutations on the app's main actor.
public struct RecordingSession: Sendable {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var generation: Int = 0

    public init() {}

    public mutating func cancel() {
        generation += 1
        phase = .idle
    }

    public mutating func complete(for generation: Int) -> Bool {
        guard self.generation == generation, phase == .uploading else { return false }
        phase = .idle
        return true
    }

    public mutating func finish() -> Int? {
        switch phase {
        case .recording:
            phase = .uploading
            return generation
        case .requestingPermission:
            generation += 1
            phase = .idle
            return nil
        case .idle, .uploading:
            return nil
        }
    }

    public mutating func permissionGranted(for generation: Int) -> Bool {
        guard self.generation == generation, phase == .requestingPermission else { return false }
        phase = .recording
        return true
    }

    @discardableResult
    public mutating func begin() -> Int? {
        guard phase == .idle else { return nil }
        generation += 1
        phase = .requestingPermission
        return generation
    }
}
