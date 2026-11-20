import Foundation

/// Pure request-handling logic for the QwenWork loopback HTTP listener
/// (docs/m2-led-design.md §4.1). QwenWork enterprise hooks are HTTP-only and
/// configured in the enterprise console; Lite receives event POSTs on
/// 127.0.0.1 and maps them through the same Claude-compatible table.
///
/// This type performs no I/O: the App shell owns the socket and feeds
/// parsed request parts in; tests drive it directly with an injected clock.
public struct VibeKeyQwenWorkHookHandler {
    public static let defaultPort = 27950
    public static let path = "/qwenwork"
    /// Events the console guide wires (subset of the 12 enterprise events
    /// that map to light states; the rest are ignored by the mapper).
    public static let wiredEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Stop", "Notification", "PreCompact",
    ]

    public struct Response: Equatable, Sendable {
        public var statusCode: Int
        public var body: String
        /// State resolved for the renderer, when the event mapped.
        public var resolvedState: VibeKeyAgentState?

        public init(statusCode: Int, body: String, resolvedState: VibeKeyAgentState? = nil) {
            self.statusCode = statusCode
            self.body = body
            self.resolvedState = resolvedState
        }
    }

    public let token: String
    public private(set) var aggregator: VibeKeyLedSessionAggregator

    public init(token: String, staleInterval: TimeInterval = 120) {
        self.token = token
        self.aggregator = VibeKeyLedSessionAggregator(staleInterval: staleInterval)
    }

    /// Handles one HTTP request. Always answers promptly; never blocks or
    /// interferes with the enterprise flow (body is `{}` on every 2xx).
    public mutating func handle(
        method: String,
        requestPath: String,
        authorizationHeader: String?,
        body: Data,
        now: TimeInterval
    ) -> Response {
        guard requestPath == Self.path else {
            return Response(statusCode: 404, body: "{}")
        }
        guard method.uppercased() == "POST" else {
            return Response(statusCode: 405, body: "{}")
        }
        guard let header = authorizationHeader,
              header == "Bearer \(token)" else {
            return Response(statusCode: 401, body: "{}")
        }
        // Bad JSON is tolerated: acknowledge without acting (the enterprise
        // client treats non-2xx as an error and logs it; we stay silent).
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Response(statusCode: 200, body: "{}")
        }
        let event = (payload["hook_event_name"] as? String)
            ?? (payload["event"] as? String)
        guard let event,
              let state = VibeKeyAgentEventMapper.claudeState(forEvent: event) else {
            // Unknown/unmapped event: acknowledge, no state change.
            return Response(statusCode: 200, body: "{}")
        }
        let session = (payload["session_id"] as? String)
            ?? (payload["sessionId"] as? String)
            ?? "qwenwork-default"
        let resolved = aggregator.record(session: session, state: state, now: now)
        return Response(statusCode: 200, body: "{}", resolvedState: resolved)
    }

    /// Prunes stale sessions; returns the state the renderer should show.
    public mutating func prune(now: TimeInterval) -> VibeKeyAgentState {
        aggregator.prune(now: now)
    }

    /// Generates the per-event Hook group JSON for pasting into the
    /// enterprise console (Security → Hooks rules). One snippet per event.
    public static func consoleSnippets(port: Int = defaultPort, token: String) -> [String: String] {
        var snippets: [String: String] = [:]
        for event in wiredEvents {
            let group: [[String: Any]] = [[
                "hooks": [[
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)\(path)",
                    "timeout": 3,
                    "headers": ["Authorization": "Bearer \(token)"],
                ]],
            ]]
            if let data = try? JSONSerialization.data(
                withJSONObject: group, options: [.sortedKeys]
            ), let text = String(data: data, encoding: .utf8) {
                snippets[event] = text
            }
        }
        return snippets
    }

    /// Fresh random bearer token (hex, 32 chars).
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The loopback bind address. Kept as a constant so tests can assert the
    /// listener never binds a routable interface.
    public static let bindAddress = "127.0.0.1"

    /// Personal-edition notice (design §4.1: hooks are enterprise-only).
    public static let personalEditionNotice =
        "千问办公 hooks 仅企业旗舰版（qwenwork_premium）支持；个人版无法接入灯效。"
}