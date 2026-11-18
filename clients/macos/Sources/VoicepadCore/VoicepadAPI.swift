import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BackendStatus: Decodable, Sendable {
    public let credentialAvailable: Bool
    public let provider: String
    public let credentialExpiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case credentialAvailable = "credential_available"
        case provider
        case credentialExpiresAt = "credential_expires_at"
    }
}

public struct Transcript: Decodable, Sendable {
    public let text: String
    public let audioSeconds: Double?
    public let elapsedSeconds: Double?
    public let warning: String?

    public func deliveryMessage(_ insertionMessage: String) -> String {
        guard warning != nil else { return insertionMessage }
        let notice = VoicepadAPI.safeMessage(warning) ?? "Formatting was unavailable; raw dictation returned."
        return notice + " " + insertionMessage
    }

    private enum CodingKeys: String, CodingKey {
        case text, warning
        case audioSeconds = "audio_seconds"
        case elapsedSeconds = "elapsed_seconds"
    }
}

public enum VoicepadError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case invalidProfileSlot
    case unsupportedMIMEType
    case emptyAudio
    case audioTooLarge
    case backend(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidProfileSlot: return "Choose a Voicepad profile from slots 1–9, or default raw."
        case .unsupportedMIMEType: return "Use a supported audio recording."
        case .emptyAudio: return "The recording was empty."
        case .audioTooLarge: return "Recording exceeds the 25 MiB limit."
        case .invalidResponse: return "The Voicepad service returned an invalid response."
        case let .backend(statusCode, message):
            if statusCode == 503 {
                return "Voicepad is disconnected. Connect Codex on the server." + (message.map { " " + $0 } ?? "")
            }
            return message ?? "The Voicepad service returned HTTP \(statusCode)."
        }
    }
}

public struct VoicepadAPI: Sendable {
    public static let serviceURL: URL = {
        do { return try ServerConfiguration.url(infoDictionary: Bundle.main.infoDictionary) }
        catch { fatalError("Invalid VoicepadServerURL in application bundle. Rebuild with a valid VOICEPAD_SERVER_URL.") }
    }()
    let session: URLSession
    private let baseURL: URL

    private static let safeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = RecordingLimits.requestTimeout
        config.timeoutIntervalForResource = RecordingLimits.resourceTimeout
        return URLSession(configuration: config, delegate: RejectRedirectDelegate(), delegateQueue: nil)
    }()

    /// The default uses an ephemeral, credential-free session which refuses all redirects.
    /// Injected sessions are for testing: their owner must enforce the same redirect policy.
    /// Passing `.shared` also selects the safe session, not the process-wide cookie store.
    public init(session: URLSession = .shared) {
        self.baseURL = Self.serviceURL
        self.session = session === URLSession.shared ? Self.safeSession : session
    }

    /// Explicit configuration for embedding/tests; production bundles use VoicepadServerURL.
    public init(serverURL: String, session: URLSession = .shared) throws {
        self.baseURL = try ServerConfiguration.url(infoDictionary: ["VoicepadServerURL": serverURL])
        self.session = session === URLSession.shared ? Self.safeSession : session
    }

    public func status() async throws -> BackendStatus {
        try await send(request(path: "api/status", method: "GET"), as: BackendStatus.self)
    }

    public func profiles() async throws -> [VoicepadProfile] {
        var request = request(path: "api/profiles", method: "GET")
        request.timeoutInterval = 5
        let envelope = try await send(request, as: ProfileEnvelope.self)
        return try VoicepadProfile.validated(envelope.profiles)
    }

    private struct ProfileEnvelope: Decodable { let profiles: [VoicepadProfile] }

    public func transcribe(audio: Data, mimeType: String, profileSlot: Int? = nil) async throws -> Transcript {
        if let profileSlot, !(1...9).contains(profileSlot) { throw VoicepadError.invalidProfileSlot }
        let supportedTypes: Set<String> = ["audio/webm", "audio/mp4", "audio/wav", "audio/x-wav",
                                           "audio/mpeg", "audio/ogg", "audio/aac", "video/mp4"]
        guard supportedTypes.contains(mimeType) else { throw VoicepadError.unsupportedMIMEType }
        guard !audio.isEmpty else { throw VoicepadError.emptyAudio }
        guard audio.count <= RecordingLimits.maximumBytes else { throw VoicepadError.audioTooLarge }
        var request = request(path: "api/transcribe", method: "POST")
        // Upload/decode + audio provider (including one refresh retry) + formatting.
        request.timeoutInterval = RecordingLimits.requestTimeout
        request.httpBody = audio
        if let profileSlot { request.setValue(String(profileSlot), forHTTPHeaderField: "X-Voicepad-Profile") }
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        return try await send(request, as: Transcript.self)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw VoicepadError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw VoicepadError.backend(statusCode: response.statusCode, message: Self.safeMessage(message))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VoicepadError.invalidResponse
        }
    }

    private struct ErrorBody: Decodable { let error: String }

    /// Accept only bounded plain-text JSON errors, never a raw HTML proxy/login response.
    fileprivate static func safeMessage(_ message: String?) -> String? {
        guard let message, !message.contains("<"), !message.contains(">") else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let words = message.components(separatedBy: separators)
        let clean = words.filter { !$0.isEmpty }.joined(separator: " ")
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(300))
    }

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("voicepad", forHTTPHeaderField: "X-Requested-With")
        return request
    }
}
