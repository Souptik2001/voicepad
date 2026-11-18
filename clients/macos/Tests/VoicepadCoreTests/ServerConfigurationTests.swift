import XCTest
import Foundation
@testable import VoicepadCore

final class ServerConfigurationTests: XCTestCase {
    func testURLValidationAndTrailingSlashNormalization() throws {
        let valid = [
            "http://localhost:8791/": "http://localhost:8791/",
            "http://127.0.0.1:8791": "http://127.0.0.1:8791/",
            "http://127.42.1.2/base": "http://127.42.1.2/base/",
            "http://[::1]:8791/voicepad/": "http://[::1]:8791/voicepad/",
            "https://your-host/voicepad": "https://your-host/voicepad/",
            "https://your-host:443/a%20b/": "https://your-host:443/a%20b/"
        ]
        for (input, expected) in valid {
            XCTAssertEqual(try ServerConfiguration.url(infoDictionary: ["VoicepadServerURL": input]).absoluteString,
                           expected, input)
        }
        for input in ["http://your-host/", "http://192.168.1.5/", "http://localhost.evil/",
                      "http://[::ffff:127.0.0.1]/", "ftp://localhost/", "/relative/", "https:///",
                      "https://user:pass@your-host/", "https://@your-host/", "https://your-host/?",
                      "https://your-host/?key=value", "https://your-host/#", "https://your-host/#fragment",
                      " https://your-host/", "https://your-host/\n", "https://your-host/a b/",
                      "https://your-host\\evil/", "https://your-host:0/", "https://your-host:65536/",
                      "https://your-host:abc/", "https://your-host:/", "https://your-host/%zz/",
                      "https://%6cocalhost/", "http://127.1/", "http://2130706433/"] {
            XCTAssertThrowsError(try ServerConfiguration.url(infoDictionary: ["VoicepadServerURL": input]), input)
        }
    }

    func testBundleConfigurationSelectsHTTPSSubpathAndDefaultsOnlyWhenAbsent() throws {
        XCTAssertEqual(try ServerConfiguration.url(infoDictionary: nil).absoluteString,
                       "http://localhost:8791/")
        XCTAssertEqual(try ServerConfiguration.url(infoDictionary: [:]).absoluteString,
                       "http://localhost:8791/")
        XCTAssertEqual(try ServerConfiguration.url(infoDictionary: [
            "VoicepadServerURL": "https://your-host/voicepad/"
        ]).absoluteString, "https://your-host/voicepad/")
        for value: Any in ["", 123, "http://your-host/"] {
            XCTAssertThrowsError(try ServerConfiguration.url(infoDictionary: ["VoicepadServerURL": value]))
        }
    }
}
