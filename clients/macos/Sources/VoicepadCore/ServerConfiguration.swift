import Foundation

public enum ServerConfiguration {
    public static let defaultURL = URL(string: "http://localhost:8791/")!

    public enum ConfigurationError: LocalizedError {
        case invalidURL
        public var errorDescription: String? {
            "VoicepadServerURL must be an HTTPS server URL (HTTP is allowed only for loopback), without credentials, query, or fragment."
        }
    }

    /// A missing bundle key selects loopback. An invalid present key is never silently ignored.
    public static func url(infoDictionary: [String: Any]?) throws -> URL {
        guard let value = infoDictionary?["VoicepadServerURL"] else { return defaultURL }
        guard let string = value as? String,
              string.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              !string.contains("\\"),
              string.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              var components = URLComponents(string: string),
              let scheme = components.scheme, ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let authority = string.components(separatedBy: "://").dropFirst().first?.components(separatedBy: "/").first,
              authority.range(of: "^(?:[A-Za-z0-9.-]+|\\[[0-9A-Fa-f:]+\\])(?::[0-9]+)?$", options: .regularExpression) != nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConfigurationError.invalidURL
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let ipv4Loopback = octets.count == 4 && octets.first == "127" && octets.allSatisfy {
            guard let number = Int($0), (0...255).contains(number) else { return false }
            return String(number) == $0
        }
        let loopback = host.lowercased() == "localhost" || host == "[::1]" || host == "::1" || ipv4Loopback
        guard scheme == "https" || loopback else { throw ConfigurationError.invalidURL }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let url = components.url else { throw ConfigurationError.invalidURL }
        return url
    }
}
