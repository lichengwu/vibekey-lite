import Foundation

/// Wire protocol between vibekeyctl and the resident Lite app.
/// One JSON object per line over a Unix domain socket.
public enum VibeKeyCtlProtocol {
    public static let socketRelativePath = "Library/Application Support/VibeKey Lite/ctl.sock"

    public struct Request: Codable, Equatable, Sendable {
        public var command: String
        public var state: String?
        public var agent: String?
        public var session: String?
        public var event: String?
        public var dialect: String?
        public var when: String?

        public init(
            command: String,
            state: String? = nil,
            agent: String? = nil,
            session: String? = nil,
            event: String? = nil,
            dialect: String? = nil,
            when: String? = nil
        ) {
            self.command = command
            self.state = state
            self.agent = agent
            self.session = session
            self.event = event
            self.dialect = dialect
            self.when = when
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var state: String?

        public init(ok: Bool, error: String? = nil, state: String? = nil) {
            self.ok = ok
            self.error = error
            self.state = state
        }
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ line: Data) -> Request? {
        try? JSONDecoder().decode(Request.self, from: line)
    }

    public static func decodeResponse(_ line: Data) -> Response? {
        try? JSONDecoder().decode(Response.self, from: line)
    }

    /// Parses a Claude-compatible hook stdin payload into a request.
    public static func requestFromHookPayload(
        _ payload: [String: Any],
        agent: String,
        dialect: String,
        fallbackEvent: String?
    ) -> Request? {
        let event = (payload["hook_event_name"] as? String)
            ?? (payload["event"] as? String)
            ?? fallbackEvent
        guard let event else { return nil }
        let session = (payload["session_id"] as? String)
            ?? (payload["sessionId"] as? String)
            ?? "default"
        let when = payload["when"] as? String
        return Request(
            command: "hook",
            agent: agent,
            session: session,
            event: event,
            dialect: dialect,
            when: when
        )
    }
}