import XCTest
import Network
import VibeKeyLiteCore
@testable import VibeKeyLite

final class QwenWorkHookListenerIntegrationTests: XCTestCase {
    private var listener: QwenWorkHookListener!
    private var receivedStates: [VibeKeyAgentState] = []

    override func setUp() {
        super.setUp()
        receivedStates = []
        // port 0 = random high port; loopback only.
        listener = QwenWorkHookListener(port: 0) { [weak self] state in
            self?.receivedStates.append(state)
        }
        try? listener.start()
        // Wait for ready.
        let deadline = Date().addingTimeInterval(3)
        while !listener.isRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    override func tearDown() {
        listener.stop()
        listener = nil
        super.tearDown()
    }

    private func rawRequest(_ text: String) -> Data {
        var response = Data()
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(listener.port))!,
            using: .tcp
        )
        let done = expectation(description: "response")
        connection.stateUpdateHandler = { state in
            if state == .ready {
                connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    if let data { response = data }
                    done.fulfill()
                }
            }
        }
        connection.start(queue: .main)
        wait(for: [done], timeout: 5)
        connection.cancel()
        return response
    }

    func testValidPostReturns200AndDeliversState() {
        XCTAssertTrue(listener.isRunning)
        let body = "{\"hook_event_name\":\"Notification\",\"session_id\":\"qw1\"}"
        let request = "POST /qwenwork HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(listener.token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let response = String(data: rawRequest(request), encoding: .utf8) ?? ""
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertTrue(response.hasSuffix("{}"), response)
        XCTAssertEqual(receivedStates, [.notification])
    }

    func testWrongTokenReturns401NoState() {
        let body = "{\"hook_event_name\":\"Stop\"}"
        let request = "POST /qwenwork HTTP/1.1\r\nAuthorization: Bearer wrong\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let response = String(data: rawRequest(request), encoding: .utf8) ?? ""
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"), response)
        XCTAssertTrue(receivedStates.isEmpty)
    }

    func testWrongPathReturns404() {
        let request = "POST /nope HTTP/1.1\r\nAuthorization: Bearer \(listener.token)\r\nContent-Length: 2\r\n\r\n{}"
        let response = String(data: rawRequest(request), encoding: .utf8) ?? ""
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404"), response)
    }

    func testBadJsonReturns200NoState() {
        let body = "{broken"
        let request = "POST /qwenwork HTTP/1.1\r\nAuthorization: Bearer \(listener.token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let response = String(data: rawRequest(request), encoding: .utf8) ?? ""
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertTrue(receivedStates.isEmpty)
    }

    func testListenerNotRunningByDefault() {
        let fresh = QwenWorkHookListener(port: 0) { _ in }
        XCTAssertFalse(fresh.isRunning, "must not start until install flow")
        fresh.stop()
    }
}
