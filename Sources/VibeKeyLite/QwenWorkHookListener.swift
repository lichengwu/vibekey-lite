import Foundation
import Network
import OSLog
import VibeKeyLiteCore

/// Loopback HTTP listener for QwenWork enterprise hooks
/// (docs/m2-led-design.md §4.1). Binds 127.0.0.1 only; started explicitly by
/// the install flow, never at app launch. All request logic lives in the
/// pure Core handler; this shell only owns the socket and HTTP framing.
final class QwenWorkHookListener {
    private let logger = Logger(subsystem: "io.github.arumwu.VibeKeyLite", category: "QwenWork")
    private var listener: NWListener?
    private var handler: VibeKeyQwenWorkHookHandler
    private let onState: (VibeKeyAgentState) -> Void
    private(set) var port: Int
    private(set) var isRunning = false

    /// - Parameters:
    ///   - port: defaults to 27950; tests may pass 0 for a random high port.
    ///   - onState: called on the main queue with the resolved render state.
    init(
        port: Int = VibeKeyQwenWorkHookHandler.defaultPort,
        token: String = VibeKeyQwenWorkHookHandler.generateToken(),
        onState: @escaping (VibeKeyAgentState) -> Void
    ) {
        self.port = port
        self.handler = VibeKeyQwenWorkHookHandler(token: token)
        self.onState = onState
    }

    var token: String { handler.token }

    func start() throws {
        guard !isRunning else { return }
        let parameters = NWParameters.tcp
        // Loopback-only: refuse any non-loopback interface.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let nwListener: NWListener
        if port == 0 {
            nwListener = try NWListener(using: parameters)
        } else {
            nwListener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: UInt16(port))!
            )
        }
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let actual = nwListener.port?.rawValue {
                    self.port = Int(actual)
                }
                self.isRunning = true
                self.logger.notice("QwenWork listener ready on 127.0.0.1:\(self.port, privacy: .public)")
            case let .failed(error):
                self.isRunning = false
                self.logger.error("QwenWork listener failed: \(error.localizedDescription, privacy: .public)")
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        nwListener.start(queue: .main)
        listener = nwListener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        logger.notice("QwenWork listener stopped")
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, accumulated: Data())
    }

    /// Reads until the HTTP header terminator, then reads the declared body
    /// length. Requests are tiny (<2 KB); a 64 KB cap guards against abuse.
    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > 65536 || error != nil {
                connection.cancel()
                return
            }
            if let request = Self.parseRequest(buffer) {
                let response = self.handler.handle(
                    method: request.method,
                    requestPath: request.path,
                    authorizationHeader: request.authorization,
                    body: request.body,
                    now: Date().timeIntervalSince1970
                )
                if let state = response.resolvedState {
                    self.onState(state)
                }
                self.send(response, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private struct ParsedRequest {
        var method: String
        var path: String
        var authorization: String?
        var body: Data
    }

    /// Minimal HTTP/1.1 request parser: request line, headers, Content-Length
    /// body. Returns nil when more bytes are needed.
    private static func parseRequest(_ buffer: Data) -> ParsedRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var authorization: String?
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "authorization" { authorization = value }
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }
        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        return ParsedRequest(
            method: method, path: path, authorization: authorization,
            body: Data(buffer[bodyStart..<bodyEnd])
        )
    }

    private func send(_ response: VibeKeyQwenWorkHookHandler.Response, on connection: NWConnection) {
        let reason: String
        switch response.statusCode {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        let body = Data(response.body.utf8)
        let head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}