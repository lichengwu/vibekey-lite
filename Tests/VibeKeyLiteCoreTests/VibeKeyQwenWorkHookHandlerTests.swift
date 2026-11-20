import XCTest
@testable import VibeKeyLiteCore

final class VibeKeyQwenWorkHookHandlerTests: XCTestCase {
    private let token = "test-token-abc123"
    private var handler = VibeKeyQwenWorkHookHandler(token: "test-token-abc123")
    private var now: TimeInterval = 1000

    override func setUp() {
        super.setUp()
        handler = VibeKeyQwenWorkHookHandler(token: token)
        now = 1000
    }

    private func post(
        event: String?,
        session: String? = "s1",
        token authToken: String? = nil,
        path: String = VibeKeyQwenWorkHookHandler.path,
        method: String = "POST",
        rawBody: Data? = nil
    ) -> VibeKeyQwenWorkHookHandler.Response {
        let body: Data
        if let rawBody {
            body = rawBody
        } else {
            var payload: [String: Any] = [:]
            if let event { payload["hook_event_name"] = event }
            if let session { payload["session_id"] = session }
            body = try! JSONSerialization.data(withJSONObject: payload)
        }
        let header = authToken.map { "Bearer \($0)" } ?? "Bearer \(token)"
        return handler.handle(
            method: method, requestPath: path,
            authorizationHeader: header, body: body, now: now
        )
    }

    // MARK: - Auth

    func testValidTokenAccepted() {
        let response = post(event: "Stop")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "{}")
        XCTAssertEqual(response.resolvedState, .attention)
    }

    func testWrongTokenRejected401() {
        let response = post(event: "Stop", token: "wrong-token")
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertNil(response.resolvedState)
    }

    func testMissingAuthHeaderRejected401() {
        let response = handler.handle(
            method: "POST", requestPath: VibeKeyQwenWorkHookHandler.path,
            authorizationHeader: nil,
            body: Data("{\"hook_event_name\":\"Stop\"}".utf8), now: now
        )
        XCTAssertEqual(response.statusCode, 401)
    }

    func testMalformedAuthSchemeRejected401() {
        let response = handler.handle(
            method: "POST", requestPath: VibeKeyQwenWorkHookHandler.path,
            authorizationHeader: "Basic \(token)",
            body: Data("{\"hook_event_name\":\"Stop\"}".utf8), now: now
        )
        XCTAssertEqual(response.statusCode, 401)
    }

    // MARK: - Routing

    func testWrongPath404() {
        let response = post(event: "Stop", path: "/other")
        XCTAssertEqual(response.statusCode, 404)
    }

    func testGetRejected405() {
        let response = post(event: "Stop", method: "GET")
        XCTAssertEqual(response.statusCode, 405)
    }

    func testLoopbackBindAddressIsFixed() {
        XCTAssertEqual(VibeKeyQwenWorkHookHandler.bindAddress, "127.0.0.1")
        XCTAssertEqual(VibeKeyQwenWorkHookHandler.defaultPort, 27950)
    }

    // MARK: - Event mapping (Claude-compatible table)

    func testAllWiredEventsMapToStates() {
        let expected: [String: VibeKeyAgentState] = [
            "SessionStart": .idle,
            "UserPromptSubmit": .thinking,
            "PreToolUse": .working,
            "PostToolUse": .working,
            "Stop": .attention,
            "Notification": .notification,
            "PreCompact": .sweeping,
        ]
        for (event, state) in expected {
            let response = post(event: event)
            XCTAssertEqual(response.statusCode, 200, event)
            XCTAssertEqual(response.resolvedState, state, event)
        }
    }

    func testEventFieldAliasAccepted() {
        let body = Data("{\"event\":\"Notification\",\"session_id\":\"s9\"}".utf8)
        let response = post(event: nil, rawBody: body)
        XCTAssertEqual(response.resolvedState, .notification)
    }

    // MARK: - Tolerance

    func testBadJsonAcknowledgedWithoutStateChange() {
        let response = post(event: nil, rawBody: Data("{not json".utf8))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "{}")
        XCTAssertNil(response.resolvedState)
    }

    func testUnknownEventAcknowledgedWithoutStateChange() {
        let response = post(event: "ConnectorAdded")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.resolvedState)
    }

    func testMissingEventFieldAcknowledged() {
        let response = post(event: nil)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.resolvedState)
    }

    func testMissingSessionUsesDefault() {
        let response = post(event: "Stop", session: nil)
        XCTAssertEqual(response.resolvedState, .attention)
        XCTAssertEqual(handler.aggregator.activeSessionCount, 1)
    }

    // MARK: - Arbitration composition

    func testNotificationWinsOverWorkingAcrossSessions() {
        _ = post(event: "PreToolUse", session: "a")
        let response = post(event: "Notification", session: "b")
        XCTAssertEqual(response.resolvedState, .notification)
        // Working updates must not dethrone notification.
        let later = post(event: "PostToolUse", session: "a")
        XCTAssertEqual(later.resolvedState, .notification)
    }

    func testStaleSessionPrunedAfter120s() {
        _ = post(event: "Notification", session: "a")
        now += 50
        _ = post(event: "PreToolUse", session: "b")
        now += 71 // session a is now 121s old
        let resolved = handler.prune(now: now)
        XCTAssertEqual(resolved, .working)
        XCTAssertEqual(handler.aggregator.activeSessionCount, 1)
    }

    func testAllSessionsStaleResolvesIdle() {
        _ = post(event: "Stop", session: "a")
        now += 200
        XCTAssertEqual(handler.prune(now: now), .idle)
    }

    // MARK: - Console snippets

    func testSnippetsCoverWiredEventsWithTokenAndLoopback() throws {
        let snippets = VibeKeyQwenWorkHookHandler.consoleSnippets(token: token)
        XCTAssertEqual(Set(snippets.keys), Set(VibeKeyQwenWorkHookHandler.wiredEvents))
        for (event, text) in snippets {
            let parsed = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
            )
            let hooks = try XCTUnwrap(parsed[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(hooks[0]["type"] as? String, "http", event)
            let url = try XCTUnwrap(hooks[0]["url"] as? String)
            XCTAssertTrue(url.hasPrefix("http://127.0.0.1:27950/qwenwork"), event)
            let headers = try XCTUnwrap(hooks[0]["headers"] as? [String: String])
            XCTAssertEqual(headers["Authorization"], "Bearer \(token)", event)
        }
    }

    func testGeneratedTokensAreRandomAndHex() {
        let first = VibeKeyQwenWorkHookHandler.generateToken()
        let second = VibeKeyQwenWorkHookHandler.generateToken()
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testPersonalEditionNoticeMentionsEnterpriseOnly() {
        XCTAssertTrue(VibeKeyQwenWorkHookHandler.personalEditionNotice.contains("企业旗舰版"))
    }
}