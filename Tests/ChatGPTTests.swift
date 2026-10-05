import XCTest
import Security
import SwiftUI
@testable import Pidgy

@MainActor
final class ChatGPTTests: XCTestCase {
    func testDynamicRegistrationAndReturningClientContract() throws {
        let initial = ChatGPTAuth.Transaction(redirectURI: "http://127.0.0.1:50001/auth/callback")
        let fields = query(initial.authorizationURL(hostID: "urn:uuid:host"))
        XCTAssertEqual(fields["client_id"], "dynamic_agent_client")
        XCTAssertEqual(fields["agent_name_hint"], "Pidgy")
        XCTAssertEqual(fields["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["code_challenge"], ChatGPTAuth.challenge(initial.verifier))
        XCTAssertTrue(fields["scope"]!.contains("chatgpt.tokens.use.direct"))
        XCTAssertThrowsError(try initial.exchangeFields(callback: ["state": initial.state, "code": "sample"]))
        XCTAssertThrowsError(try initial.exchangeFields(callback: ["state": "wrong", "code": "sample", "client_id": "oaiapp_test"]))
        let exchange = try initial.exchangeFields(callback: ["state": initial.state, "code": "sample", "client_id": "oaiapp_test"])
        XCTAssertEqual(exchange["redirect_uri"], fields["redirect_uri"])
        XCTAssertEqual(exchange["client_id"], "oaiapp_test")
        XCTAssertNil(exchange["client_secret"])

        let returning = ChatGPTAuth.Transaction(redirectURI: initial.redirectURI, clientID: "oaiapp_saved")
        let again = query(returning.authorizationURL(hostID: "urn:uuid:host", idTokenHint: "hint"))
        XCTAssertNil(again["agent_name_hint"])
        XCTAssertEqual(again["id_token_hint"], "hint")
        XCTAssertEqual(try returning.exchangeFields(callback: ["state": returning.state, "code": "code"])["client_id"], "oaiapp_saved")
        XCTAssertThrowsError(try returning.exchangeFields(callback: ["state": returning.state, "code": "code", "client_id": "oaiapp_other"]))
        XCTAssertThrowsError(try returning.exchangeFields(callback: ["state": returning.state, "code": "code"], now: returning.createdAt.addingTimeInterval(301)))
        XCTAssertThrowsError(try returning.exchangeFields(callback: ["state": returning.state, "error": "access_denied", "code": "code"]))
    }

    func testCallbackIgnoresUnrelatedRequestsAndRejectsDuplicateState() {
        func parse(_ line: String) -> [String: String]? {
            ChatGPTCallbackServer.parameters(request: line + "\r\nHost: 127.0.0.1\r\n\r\n", expectedState: "expected")
        }
        XCTAssertNil(parse("GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(parse("GET /auth/callback?state=wrong&code=x HTTP/1.1"))
        XCTAssertNil(parse("POST /auth/callback?state=expected&code=x HTTP/1.1"))
        XCTAssertNil(parse("GET /auth/callback?state=expected&state=wrong&code=x HTTP/1.1"))
        XCTAssertNil(parse("GET //evil.example/auth/callback?state=expected&code=x HTTP/1.1"))
        XCTAssertEqual(parse("GET /auth/callback?state=expected&code=a%2Bb&scope=openid+email HTTP/1.1")?["code"], "a+b")
        XCTAssertEqual(parse("GET /auth/callback?state=expected&error=access_denied HTTP/1.1")?["error"], "access_denied")
    }

    func testListenerReadyBeforeCallbackAndCancellationReleasesWaiter() async throws {
        let server = ChatGPTCallbackServer(expectedState: "expected")
        let port = try await server.start()
        XCTAssertGreaterThan(port, 0)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let waiter = Task { try await server.wait() }
        let (_, callback) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?state=expected&code=sample&client_id=oaiapp_test")!)
        XCTAssertEqual((callback as? HTTPURLResponse)?.statusCode, 200)
        let result = try await waiter.value
        XCTAssertEqual(result["code"], "sample")
        let cancelled = ChatGPTCallbackServer(expectedState: "other")
        _ = try await cancelled.start()
        let waiting = Task { try await cancelled.wait() }
        cancelled.cancel()
        do { _ = try await waiting.value; XCTFail("cancel must fail") } catch is CancellationError { }
    }

    func testSignedIdentityRequiresSignatureIssuerAudienceExpiryAndNonce() throws {
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // The Security API returns a PKCS#1 sequence of modulus and exponent.
        var index = 1
        _ = derLength(der, &index)
        XCTAssertEqual(der[index], 2); index += 1
        let nLength = derLength(der, &index); let n = der.subdata(in: index..<(index + nLength)); index += nLength
        XCTAssertEqual(der[index], 2); index += 1
        let eLength = derLength(der, &index); let e = der.subdata(in: index..<(index + eLength))
        let jwks = try JSONDecoder().decode(ChatGPTAuth.JWKS.self, from: JSONSerialization.data(withJSONObject: ["keys": [
            ["kty": "RSA", "kid": "test-key", "alg": "RS256", "n": ChatGPTAuth.encodeURL(n), "e": ChatGPTAuth.encodeURL(e)]
        ]]))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let claims: [String: Any] = ["iss": ChatGPTAuth.issuer, "aud": "oaiapp_test", "sub": "opaque-subject",
                                   "nonce": "nonce", "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(60).timeIntervalSince1970]
        func signed(_ overrides: [String: Any] = [:], algorithm: String = "RS256") throws -> String {
            let header = ChatGPTAuth.encodeURL(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "test-key"]))
            let payload = ChatGPTAuth.encodeURL(try JSONSerialization.data(withJSONObject: claims.merging(overrides) { _, new in new }))
            let content = header + "." + payload
            let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(content.utf8) as CFData, nil)) as Data
            return content + "." + ChatGPTAuth.encodeURL(signature)
        }
        let good = try signed()
        XCTAssertEqual(try ChatGPTAuth.validateIDToken(good, keys: jwks, clientID: "oaiapp_test", nonce: "nonce", now: now).subject, "opaque-subject")
        for wrong in [["iss": "https://other.example"], ["aud": "oaiapp_other"], ["nonce": "wrong"],
                      ["sub": ""], ["exp": now.addingTimeInterval(-10).timeIntervalSince1970],
                      ["iat": now.addingTimeInterval(60).timeIntervalSince1970], ["aud": ["oaiapp_test", "other"]]] as [[String: Any]] {
            XCTAssertThrowsError(try ChatGPTAuth.validateIDToken(signed(wrong), keys: jwks, clientID: "oaiapp_test", nonce: "nonce", now: now))
        }
        XCTAssertThrowsError(try ChatGPTAuth.validateIDToken(signed(algorithm: "none"), keys: jwks, clientID: "oaiapp_test", nonce: "nonce", now: now))
        var damaged = good.split(separator: ".").map(String.init)
        damaged[1] = ChatGPTAuth.encodeURL(Data("{}".utf8))
        XCTAssertThrowsError(try ChatGPTAuth.validateIDToken(damaged.joined(separator: "."), keys: jwks, clientID: "oaiapp_test", nonce: "nonce", now: now))
    }

    func testResponsesContractAndCompletedStream() throws {
        let body = ChatGPTProvider.body(model: "account-model", instructions: "instructions", input: "hello")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["input"] as? [[String: String]])
        for field in ["temperature", "max_output_tokens", "previous_response_id", "messages", "prompt", "background"] { XCTAssertNil(body[field]) }
        var stream = ChatGPTResponseStream()
        try stream.consume(#"{"type":"response.output_text.delta","delta":"Hello"}"#)
        XCTAssertThrowsError(try stream.result(), "a delta without completion isn't a successful response")
        try stream.consume(#"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":20,"output_tokens":5,"input_tokens_details":{"cached_tokens":10}}}}"#)
        XCTAssertEqual(try stream.result(), "Hello")
        XCTAssertEqual(stream.usage?.cachedInputTokens, 10)
        XCTAssertNil(AIUsagePricingCatalog.pricing(for: .chatGPT, model: "gpt-6-luna"))
    }

    func testFailureAfterDeltasDoesNotReturnPartialAnswer() throws {
        for terminal in [#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#,
                         #"{"type":"response.incomplete"}"#, #"{"type":"error","code":"subscription_sharing_usage_unavailable"}"#] {
            var stream = ChatGPTResponseStream()
            try stream.consume(#"{"type":"response.output_text.delta","delta":"Partial"}"#)
            XCTAssertThrowsError(try stream.consume(terminal))
            XCTAssertThrowsError(try stream.result())
        }
    }

    func testRefreshIsSerializedAndRotatedTokensSavedTogether() async throws {
        var calls = 0; var saved: ChatGPTService.Vault?
        let record = registration()
        let service = ChatGPTService(testingVault: .init(registrations: [record], activeID: record.id), transport: { request in
            calls += 1
            XCTAssertEqual(queryBody(request)["client_id"], record.id)
            XCTAssertEqual(queryBody(request)["refresh_token"], "old-refresh")
            XCTAssertNil(queryBody(request)["scope"])
            try await Task.sleep(nanoseconds: 10_000_000)
            return (Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#.utf8), http(request, status: 200))
        }, saveVault: { saved = $0 })
        async let first = service.accessToken(for: record.id)
        async let second = service.accessToken(for: record.id)
        let results = try await [first, second]
        XCTAssertEqual(results, ["new-access", "new-access"]); XCTAssertEqual(calls, 1)
        XCTAssertEqual(saved?.registrations.first?.refreshToken, "new-refresh")
        XCTAssertEqual(saved?.registrations.first?.accessToken, "new-access")
    }

    func testTemporaryRefreshFailurePreservesCredentialsTerminalFailureClearsThem() async throws {
        let record = registration()
        for code in ["temporarily_unavailable", "invalid_grant"] {
            let service = ChatGPTService(testingVault: .init(registrations: [record], activeID: record.id), transport: { request in
                (Data("{\"error\":\"\(code)\"}".utf8), http(request, status: 503))
            })
            do { _ = try await service.accessToken(for: record.id); XCTFail("must fail") } catch { }
            XCTAssertEqual(service.registrations.first?.refreshToken, code == "invalid_grant" ? nil : "old-refresh")
            XCTAssertEqual(service.registrations.first?.clientID, record.id)
        }
    }

    func testNoScopeCannotRunAndNoCashFallbackIsConfigured() async throws {
        var record = registration(); record.scopes = ["openid"]
        var calls = 0
        let service = ChatGPTService(testingVault: .init(registrations: [record], activeID: record.id), transport: { request in
            calls += 1; return (Data(), http(request, status: 200))
        })
        do { _ = try await service.accessToken(for: record.id); XCTFail("missing scopes must fail") } catch { }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(KeychainManager.usesNativeKeychainInProductionForTesting(.chatGPTAccounts))
    }

    func testSSEFramingPreservesDelimitersUTF8AndRejectsTruncatedStream() throws {
        let wire = ": heartbeat\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 👋\"}\r\n\r\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        var framing = ChatGPTSSEFraming(); var stream = ChatGPTResponseStream()
        for byte in wire.utf8 { if let event = try framing.append(byte) { try stream.consume(event) } }
        XCTAssertEqual(try stream.result(), "Hello 👋")
        var truncated = ChatGPTSSEFraming(); var incomplete = ChatGPTResponseStream()
        for byte in wire.dropLast(1).utf8 { if let event = try truncated.append(byte) { try incomplete.consume(event) } }
        XCTAssertThrowsError(try incomplete.result())
    }

    func testPermissionLossKeepsRotatedRefreshTokenAndDisablesInference() async throws {
        let record = registration(); var saved: ChatGPTService.Vault?
        let service = ChatGPTService(testingVault: .init(registrations: [record], activeID: record.id), transport: { request in
            (Data(#"{"access_token":"new-access","refresh_token":"rotated","token_type":"Bearer","expires_in":3600,"scope":"openid"}"#.utf8), http(request, status: 200))
        }, saveVault: { saved = $0 })
        do { _ = try await service.accessToken(for: record.id); XCTFail("must require plan permission") } catch { }
        XCTAssertEqual(saved?.registrations.first?.refreshToken, "rotated")
        XCTAssertFalse(service.active!.canUsePlan)
    }

    func testSignOutRevokesThenClearsTokensButRetainsRegistration() async throws {
        let record = registration(); var requests: [URLRequest] = []; var saved: ChatGPTService.Vault?
        let service = ChatGPTService(testingVault: .init(registrations: [record], activeID: record.id), transport: { request in
            requests.append(request)
            if requests.count == 1 {
                return (Data(#"{"revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#.utf8), http(request, status: 200))
            }
            XCTAssertEqual(queryBody(request)["client_id"], record.id)
            XCTAssertEqual(queryBody(request)["token"], "old-refresh")
            return (Data(), http(request, status: 200))
        }, saveVault: { saved = $0 })
        try await service.signOut()
        XCTAssertEqual(requests.count, 2); XCTAssertNil(saved?.activeID)
        XCTAssertEqual(saved?.registrations.first?.clientID, record.id)
        XCTAssertNil(saved?.registrations.first?.refreshToken)
        XCTAssertNil(saved?.registrations.first?.accessToken)
    }

    func testResponsesHTTPStreamingContractAndInterruptedBody() async throws {
        let completed = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Demo 👋\"}\r\n\r\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\r\n\r\n"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ChatGPTMockProtocol.responder = nil }
        ChatGPTMockProtocol.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertNil(body["temperature"])
            return Data(completed.utf8)
        }
        let provider = ChatGPTProvider(model: "catalog-model", token: { "test-access" }, session: session,
                                       recordUsage: { _, _, _ in })
        let answer = try await provider.answer(systemPrompt: "Synthetic instructions", userMessage: "Synthetic input")
        XCTAssertEqual(answer, "Demo 👋")
        ChatGPTMockProtocol.responder = { _ in
            Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n".utf8)
        }
        do { _ = try await provider.answer(systemPrompt: "", userMessage: "demo"); XCTFail("interrupted stream must fail") }
        catch { }
    }

    func testChatGPTPlanCannotEnableSeparatelyBilledTypeSafe() async throws {
        let ai = AIService(testingProvider: NoAIProvider(), providerType: .chatgpt, isConfigured: true)
        do { _ = try await ai.enableTypeSafe(apiKey: "synthetic"); XCTFail("must not call the separate provider") }
        catch { XCTAssertTrue(error.localizedDescription.contains("billed separately")) }
        XCTAssertNil(ai.typeSafeClient)
    }

    func testConnectionScreenRendersForSourceBuild() throws {
        XCTAssertTrue(BundledSecrets.chatGPTLocalOSS)
        let ai = AIService(testingProvider: NoAIProvider(), providerType: .none, isConfigured: false)
        let host = NSHostingView(rootView: ChatGPTConnectionView().environmentObject(ai)
            .padding(24).frame(width: 680, height: 280).background(Color.Pidgy.bg1).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 280)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let path = ProcessInfo.processInfo.environment["PIDGY_UI_SNAPSHOT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    private func registration() -> ChatGPTService.Registration {
        .init(clientID: "oaiapp_test", subject: "subject", email: "test@example.com", name: nil,
              accessToken: "old-access", refreshToken: "old-refresh", idToken: nil,
              expiresAt: Date().addingTimeInterval(-1), scopes: ["resource.invoke", "chatgpt.tokens.use.direct"])
    }
    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    }
    private func derLength(_ data: Data, _ index: inout Int) -> Int {
        let first = data[index]; index += 1
        if first < 128 { return Int(first) }
        var length = 0
        for _ in 0..<Int(first & 127) { length = length * 256 + Int(data[index]); index += 1 }
        return length
    }
}

private func queryBody(_ request: URLRequest) -> [String: String] {
    let raw = String(data: request.httpBody!, encoding: .utf8)!
    return Dictionary(uniqueKeysWithValues: URLComponents(string: "https://example.com/?" + raw)!.queryItems!.map { ($0.name, $0.value!) })
}
private func http(_ request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private final class ChatGPTMockProtocol: URLProtocol {
    static var responder: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.responder!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for index in stride(from: 0, to: data.count, by: 5) {
                client?.urlProtocol(self, didLoad: data.subdata(in: index..<min(index + 5, data.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
