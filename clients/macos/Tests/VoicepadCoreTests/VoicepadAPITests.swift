import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VoicepadCore

/// URLProtocol replaces only the transport; requests and decoding are real.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (URLResponse, Data))?
    static var handler: ((URLRequest) throws -> (URLResponse, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class VoicepadAPITests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StubURLProtocol.handler = nil
    }
    private func respond(_ body: String, status: Int = 200,
                         inspect: @escaping (URLRequest) -> Void = { _ in }) {
        StubURLProtocol.handler = { request in
            inspect(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!,
                    Data(body.utf8))
        }
    }

    func testConfiguredServiceSubpathIsUsedForAllRequests() async throws {
        let api = try VoicepadAPI(serverURL: "http://localhost:8791/custom/base", session: session)
        respond("{\"credential_available\":false,\"provider\":\"codex-subscription\"}") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8791/custom/base/api/status")
        }
        _ = try await api.status()
        respond("{\"profiles\":[]}") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8791/custom/base/api/profiles")
        }
        _ = try await api.profiles()
        respond("{\"text\":\"ok\"}") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8791/custom/base/api/transcribe")
        }
        _ = try await api.transcribe(audio: Data([1]), mimeType: "audio/wav")
        XCTAssertThrowsError(try VoicepadAPI(serverURL: "http://your-host/", session: session))
    }

    func testDefaultServiceIsLoopbackWithoutAnInternetDependency() {
        XCTAssertEqual(VoicepadAPI.serviceURL.absoluteString, "http://localhost:8791/")
    }

    func testWarningIsVisibleAlongsidePasteFailureWithoutChangingTranscript() throws {
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data("{\"text\":\"raw words\",\"warning\":\"Formatting failed.\\nRaw returned.\"}".utf8))
        XCTAssertEqual(transcript.deliveryMessage("Target changed; use Copy."), "Formatting failed. Raw returned. Target changed; use Copy.")
        XCTAssertEqual(transcript.text, "raw words")
        let unsafe = try JSONDecoder().decode(Transcript.self, from: Data("{\"text\":\"safe\",\"warning\":\"<html>error</html>\"}".utf8))
        XCTAssertEqual(unsafe.deliveryMessage("Paste sent; check field."), "Formatting was unavailable; raw dictation returned. Paste sent; check field.")
    }

    func testProfilesUseBoundedGETAndDecodeFixedSlots() async throws {
        respond("{\"profiles\":[{\"slot\":9,\"name\":\"Official\",\"instructions\":\"Be formal\"}]}") { request in
            XCTAssertEqual(request.url?.path, "/api/profiles")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "voicepad")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
            XCTAssertGreaterThan(request.timeoutInterval, 0)
        }
        let profiles = try await VoicepadAPI(session: session).profiles()
        XCTAssertEqual(profiles, [VoicepadProfile(slot: 9, name: "Official", instructions: "Be formal")])
        for body in ["{\"profiles\":[{\"slot\":10,\"name\":\"Bad\",\"instructions\":\"\"}]}",
                     "{\"profiles\":[{\"slot\":1,\"name\":\"A\",\"instructions\":\"\"},{\"slot\":1,\"name\":\"B\",\"instructions\":\"\"}]}"] {
            respond(body)
            do { _ = try await VoicepadAPI(session: session).profiles(); XCTFail("Invalid catalog accepted") }
            catch { XCTAssertEqual(error as? VoicepadError, .invalidResponse) }
        }
    }

    func testProfileHeaderIsOptionalAndWarningPreservesRawTranscript() async throws {
        for slot in [nil, 1, 9] as [Int?] {
            respond("{\"text\":\"raw words\",\"warning\":\"Formatting unavailable. Raw dictation returned.\"}") { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voicepad-Profile"), slot.map(String.init))
                XCTAssertEqual(request.httpBody, Data([1]))
                XCTAssertEqual(request.timeoutInterval, RecordingLimits.requestTimeout)
            }
            let transcript = try await VoicepadAPI(session: session).transcribe(audio: Data([1]), mimeType: "audio/wav", profileSlot: slot)
            XCTAssertEqual(transcript.text, "raw words")
            XCTAssertEqual(transcript.warning, "Formatting unavailable. Raw dictation returned.")
        }
        respond("{\"text\":\"old server\"}") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Voicepad-Profile"))
        }
        let old = try await VoicepadAPI(session: session).transcribe(audio: Data([1]), mimeType: "audio/wav")
        XCTAssertNil(old.warning)
        for slot in [0, -1, 10] {
            do {
                _ = try await VoicepadAPI(session: session).transcribe(audio: Data([1]), mimeType: "audio/wav", profileSlot: slot)
                XCTFail("Invalid slot accepted")
            } catch { XCTAssertEqual(error as? VoicepadError, .invalidProfileSlot) }
        }
    }

    func testDefaultSessionHasNoStoredCredentialsOrCookiesAndRejectsRedirects() async {
        let api = VoicepadAPI()
        XCTAssertFalse(api.session === URLSession.shared)
        XCTAssertTrue(api.session.delegate is RejectRedirectDelegate)
        XCTAssertNil(api.session.configuration.urlCredentialStorage)
        XCTAssertNil(api.session.configuration.httpCookieStorage)
        XCTAssertFalse(api.session.configuration.httpShouldSetCookies)
        XCTAssertEqual(api.session.configuration.timeoutIntervalForRequest, 330)
        XCTAssertEqual(api.session.configuration.timeoutIntervalForResource, 360)
        guard let delegate = api.session.delegate as? RejectRedirectDelegate else { return }
        for destination in ["https://attacker.invalid/collect", "https://localhost:8791/api/transcribe",
                            "http://localhost:8791/other"] {
            let original = VoicepadAPI.serviceURL.appendingPathComponent("api/transcribe")
            let task = api.session.dataTask(with: original)
            let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil,
                                           headerFields: ["Location": destination])!
            let called = expectation(description: "Redirect denied")
            delegate.urlSession(api.session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: destination)!)) { redirectedRequest in
                XCTAssertNil(redirectedRequest)
                called.fulfill()
            }
            await fulfillment(of: [called], timeout: 1)
            task.cancel()
        }
    }

    func testBackendErrorsAreSafeAndDisconnectedIsActionable() async {
        let cases: [(Int, String, String)] = [
            (429, "{\"error\":\"Another transcription is running. Try again shortly.\"}",
             "Another transcription is running. Try again shortly."),
            (503, "{\"error\":\"Connect Codex again.\",\"code\":\"reconnect_required\"}",
             "Voicepad is disconnected. Connect Codex on the server. Connect Codex again."),
            (502, "<html><body>private proxy stack trace</body></html>",
             "The Voicepad service returned HTTP 502."),
            (500, "{\"error\":\"<script>private</script>\"}", "The Voicepad service returned HTTP 500."),
            (400, "{\"error\":\"Please\\nretry.\"}", "Please retry.")
        ]
        for (status, body, message) in cases {
            respond(body, status: status)
            do {
                _ = try await VoicepadAPI(session: session).transcribe(audio: Data([1]), mimeType: "audio/wav")
                XCTFail("Expected HTTP error")
            } catch {
                XCTAssertTrue(error is VoicepadError)
                XCTAssertEqual(error.localizedDescription, message)
            }
        }
    }

    func testMalformedSuccessAndNonHTTPResponsesAreInvalidResponse() async {
        for body in ["<html>login</html>", "{}", "{\"text\":12}"] {
            respond(body)
            do {
                _ = try await VoicepadAPI(session: session).transcribe(audio: Data([1]), mimeType: "audio/wav")
                XCTFail("Expected invalid response")
            } catch {
                XCTAssertEqual(error as? VoicepadError, .invalidResponse)
            }
        }
        StubURLProtocol.handler = { request in
            (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        do {
            _ = try await VoicepadAPI(session: session).status()
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(error as? VoicepadError, .invalidResponse)
        }
    }

    func testStatusErrorsUseTheSameSafeHandling() async {
        respond("{\"error\":\"Service temporarily unavailable.\"}", status: 502)
        do {
            _ = try await VoicepadAPI(session: session).status()
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Service temporarily unavailable.")
        }
    }

    func testErrorMessageRemovesControlAndBidirectionalFormattingCharacters() async {
        respond("{\"error\":\"Please\\u0000retry\\u001b.\\u202E\"}", status: 400)
        do {
            _ = try await VoicepadAPI(session: session).status()
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Please retry .")
        }
    }

    func testOptionalTimingAndCredentialExpiryMayBeMissing() async throws {
        respond("{\"text\":\"Hello\"}")
        let transcript = try await VoicepadAPI(session: session).transcribe(audio: Data([1]), mimeType: "audio/mp4")
        XCTAssertEqual(transcript.text, "Hello")
        XCTAssertNil(transcript.audioSeconds)
        XCTAssertNil(transcript.elapsedSeconds)
        respond("{\"credential_available\":false,\"provider\":\"codex-subscription\"}")
        let status = try await VoicepadAPI(session: session).status()
        XCTAssertFalse(status.credentialAvailable)
        XCTAssertNil(status.credentialExpiresAt)
    }

    func testAllSupportedAudioTypesAndExactSizeLimitAreAccepted() async throws {
        let api = VoicepadAPI(session: session)
        for mimeType in ["audio/webm", "audio/mp4", "audio/wav", "audio/x-wav", "audio/mpeg", "audio/ogg", "audio/aac", "video/mp4"] {
            respond("{\"text\":\"ok\"}") { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), mimeType)
            }
            _ = try await api.transcribe(audio: Data([1]), mimeType: mimeType)
        }
        respond("{\"text\":\"ok\"}") { request in
            XCTAssertEqual(request.httpBody?.count, 25 * 1024 * 1024)
        }
        _ = try await api.transcribe(audio: Data(repeating: 0, count: 25 * 1024 * 1024), mimeType: "audio/wav")
    }

    func testSizeErrorShows25MiBLimit() {
        XCTAssertEqual(VoicepadError.audioTooLarge.localizedDescription, "Recording exceeds the 25 MiB limit.")
    }

    func testNetworkCancellationIsPreserved() async {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await VoicepadAPI(session: session).status()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    func testInvalidAudioIsRejectedBeforeNetwork() async {
        StubURLProtocol.handler = { _ in
            XCTFail("Invalid audio must not leave the client")
            throw URLError(.badServerResponse)
        }
        let api = VoicepadAPI(session: session)
        for (audio, mimeType, expected) in [
            (Data([1]), "text/plain", VoicepadError.unsupportedMIMEType),
            (Data([1]), "audio/wav\r\nAuthorization: secret", .unsupportedMIMEType),
            (Data(), "audio/wav", .emptyAudio),
            (Data(repeating: 0, count: 25 * 1024 * 1024 + 1), "audio/wav", .audioTooLarge)
        ] {
            do {
                _ = try await api.transcribe(audio: audio, mimeType: mimeType)
                XCTFail("Expected rejection")
            } catch {
                XCTAssertEqual(error as? VoicepadError, expected)
            }
        }
    }

    func testTranscribePostsRawAudioAndDecodesTiming() async throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        respond("{\"text\":\"Hello world\",\"audio_seconds\":1.5,\"elapsed_seconds\":0.75}") { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8791/api/transcribe")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "voicepad")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpBody, audio)
            XCTAssertEqual(request.timeoutInterval, 330)
        }
        let result = try await VoicepadAPI(session: session).transcribe(audio: audio, mimeType: "audio/wav")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.audioSeconds, 1.5)
        XCTAssertEqual(result.elapsedSeconds, 0.75)
    }

    func testStatusUsesConfiguredRouteNoAuthorizationAndDecodesSnakeCase() async throws {
        respond("""
        {"credential_available":true,"provider":"codex-subscription","credential_expires_at":"2026-11-11T00:00:00Z"}
        """) { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8791/api/status")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "voicepad")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
            XCTAssertGreaterThan(request.timeoutInterval, 0)
            XCTAssertLessThanOrEqual(request.timeoutInterval, 90)
        }
        let status = try await VoicepadAPI(session: session).status()
        XCTAssertTrue(status.credentialAvailable)
        XCTAssertEqual(status.provider, "codex-subscription")
        XCTAssertEqual(status.credentialExpiresAt, "2026-11-11T00:00:00Z")
    }
}
