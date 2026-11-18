import Foundation

/// Shared capture/upload policy; independent of the native microphone adapter.
public enum RecordingLimits {
    public static let maximumBytes = 25 * 1024 * 1024
    public static let maximumSeconds: Double = 600
    public static let requestTimeout: TimeInterval = 330
    public static let resourceTimeout: TimeInterval = 360
    /// AAC container padding must still fit inside the decoded-duration limit.
    public static let captureSeconds = maximumSeconds - 0.2

    public static func acceptsDuration(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds <= maximumSeconds
    }
}
