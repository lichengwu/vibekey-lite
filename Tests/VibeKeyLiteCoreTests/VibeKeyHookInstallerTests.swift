import XCTest
@testable import VibeKeyLiteCore

final class VibeKeyHookInstallerTests: XCTestCase {
    private let ctl = "/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl"

    private func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMergeIntoEmptyCreatesAllEvents() throws {
        let data = try VibeKeyHookInstaller.mergedSettings(
            existing: nil, target: .qoder, ctlPath: ctl
        )
        let root = try parse(data)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in VibeKeyAgentTarget.claudeEvents {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
            XCTAssertEqual(groups.count, 1, event)
            let entries = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(entries[0]["name"] as? String, "vibekey-lite")
            let command = try XCTUnwrap(entries[0]["command"] as? String)
            XCTAssertTrue(command.contains("--agent qoder"))
            XCTAssertTrue(command.contains("--event \(event)"))
        }
        XCTAssertTrue(VibeKeyHookInstaller.containsMarker(in: root))
    }

    func testMergePreservesExistingHooks() throws {
        let existing: [String: Any] = [
            "someOtherSetting": true,
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [["type": "command", "name": "user-own", "command": "/bin/echo hi"]],
                    ],
                ],
            ],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing)
        let merged = try VibeKeyHookInstaller.mergedSettings(
            existing: existingData, target: .claudeCode, ctlPath: ctl
        )
        let root = try parse(merged)
        XCTAssertEqual(root["someOtherSetting"] as? Bool, true)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        let userGroup = groups.first { ($0["matcher"] as? String) == "Bash" }
        let userEntries = try XCTUnwrap(userGroup?["hooks"] as? [[String: Any]])
        XCTAssertEqual(userEntries[0]["name"] as? String, "user-own")
    }

    func testReinstallIsIdempotent() throws {
        let first = try VibeKeyHookInstaller.mergedSettings(
            existing: nil, target: .qoder, ctlPath: ctl
        )
        let second = try VibeKeyHookInstaller.mergedSettings(
            existing: first, target: .qoder, ctlPath: ctl
        )
        let root = try parse(second)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in VibeKeyAgentTarget.claudeEvents {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(groups.count, 1, "duplicate group for \(event)")
        }
    }

    func testUninstallRemovesOnlyMarkerEntries() throws {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "name": "user-own", "command": "/bin/true"],
                            ["type": "command", "name": "vibekey-lite", "command": "x"],
                        ],
                    ],
                ],
            ],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing)
        let unmerged = try XCTUnwrap(
            VibeKeyHookInstaller.unmergedSettings(existing: existingData)
        )
        let root = try parse(unmerged)
        XCTAssertFalse(VibeKeyHookInstaller.containsMarker(in: root))
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let entries = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["name"] as? String, "user-own")
    }

    func testUninstallWithoutMarkerReturnsNil() throws {
        let existing = try JSONSerialization.data(withJSONObject: ["hooks": [String: Any]()])
        XCTAssertNil(try VibeKeyHookInstaller.unmergedSettings(existing: existing))
    }

    func testInvalidExistingJSONIsRejected() {
        let garbage = Data("{not json".utf8)
        XCTAssertThrowsError(
            try VibeKeyHookInstaller.mergedSettings(existing: garbage, target: .qoder, ctlPath: ctl)
        ) { error in
            XCTAssertEqual(error as? VibeKeyHookInstallerError, .invalidExistingJSON)
        }
    }

    func testQwenWorkAndDshRejectLocalMerge() {
        XCTAssertThrowsError(
            try VibeKeyHookInstaller.mergedSettings(existing: nil, target: .qwenwork, ctlPath: ctl)
        )
        XCTAssertThrowsError(
            try VibeKeyHookInstaller.mergedSettings(existing: nil, target: .dsh, ctlPath: ctl)
        )
    }

    func testDetectionWithTempHome() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibekey-test-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".qoder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let qoder = VibeKeyHookInstaller.detect(target: .qoder, homeDirectory: home)
        XCTAssertTrue(qoder.detected)
        XCTAssertFalse(qoder.installed)

        let claude = VibeKeyHookInstaller.detect(target: .claudeCode, homeDirectory: home)
        XCTAssertFalse(claude.detected)

        // Installed flag flips after a merge is written.
        let settingsURL = home.appendingPathComponent(".qoder/settings.json")
        let merged = try VibeKeyHookInstaller.mergedSettings(existing: nil, target: .qoder, ctlPath: ctl)
        try merged.write(to: settingsURL)
        let after = VibeKeyHookInstaller.detect(target: .qoder, homeDirectory: home)
        XCTAssertTrue(after.installed)
    }

    // MARK: - Ctl protocol

    func testRequestRoundTrip() throws {
        let request = VibeKeyCtlProtocol.Request(
            command: "hook", agent: "qoder", session: "s1", event: "Stop", dialect: "claude"
        )
        let line = try VibeKeyCtlProtocol.encodeLine(request)
        XCTAssertEqual(line.last, 0x0A)
        let decoded = try XCTUnwrap(VibeKeyCtlProtocol.decodeRequest(line))
        XCTAssertEqual(decoded, request)
    }

    func testHookPayloadParsing() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": "abc",
        ]
        let request = try XCTUnwrap(
            VibeKeyCtlProtocol.requestFromHookPayload(
                payload, agent: "claude-code", dialect: "claude", fallbackEvent: nil
            )
        )
        XCTAssertEqual(request.event, "Notification")
        XCTAssertEqual(request.session, "abc")
        XCTAssertEqual(request.command, "hook")
    }

    func testHookPayloadFallsBackToArgvEvent() {
        let request = VibeKeyCtlProtocol.requestFromHookPayload(
            [:], agent: "codex", dialect: "claude", fallbackEvent: "Stop"
        )
        XCTAssertEqual(request?.event, "Stop")
        XCTAssertEqual(request?.session, "default")
        XCTAssertNil(
            VibeKeyCtlProtocol.requestFromHookPayload(
                [:], agent: "codex", dialect: "claude", fallbackEvent: nil
            )
        )
    }
}