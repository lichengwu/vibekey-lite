import XCTest
@testable import VibeKeyLiteCore

final class VibeKeyLedPatternTests: XCTestCase {
    // MARK: - Event mapping (official ustudio-cli tables)

    func testClaudeEventMapping() {
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "SessionStart"), .idle)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "UserPromptSubmit"), .thinking)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "PreToolUse"), .working)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "PostToolUse"), .working)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "Stop"), .attention)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "Notification"), .notification)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "PermissionRequest"), .notification)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "PostToolUseFailure"), .error)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "PreCompact"), .sweeping)
        XCTAssertEqual(VibeKeyAgentEventMapper.claudeState(forEvent: "SessionEnd"), .sleeping)
        XCTAssertNil(VibeKeyAgentEventMapper.claudeState(forEvent: "ConfigChange"))
    }

    func testDshEventMapping() {
        XCTAssertEqual(VibeKeyAgentEventMapper.dshState(forEvent: "turn/end", when: "completed"), .attention)
        XCTAssertEqual(VibeKeyAgentEventMapper.dshState(forEvent: "turn/end", when: "error"), .error)
        XCTAssertEqual(VibeKeyAgentEventMapper.dshState(forEvent: "tool/call"), .working)
        XCTAssertEqual(VibeKeyAgentEventMapper.dshState(forEvent: "approval/asked"), .notification)
        XCTAssertEqual(VibeKeyAgentEventMapper.dshState(forEvent: "agent/error"), .error)
        XCTAssertEqual(
            VibeKeyAgentEventMapper.state(agentDialect: "dsh", event: "approval/asked"),
            .notification
        )
        XCTAssertEqual(
            VibeKeyAgentEventMapper.state(agentDialect: "claude-code", event: "Stop"),
            .attention
        )
    }

    func testPriorityOrdering() {
        let ordered: [VibeKeyAgentState] = [
            .notification, .error, .sweeping, .thinking, .working, .attention, .idle,
        ]
        let priorities = ordered.map(\.priority)
        XCTAssertEqual(priorities, priorities.sorted(by: >))
        XCTAssertTrue(VibeKeyAgentState.notification.bypassesDebounce)
        XCTAssertTrue(VibeKeyAgentState.error.bypassesDebounce)
        XCTAssertFalse(VibeKeyAgentState.working.bypassesDebounce)
    }

    // MARK: - Static tables

    func testIdleTurnsEverythingOffButKeepsVoiceKeyTuple() {
        let voice = VibeKeyLedState.baseline.leds[0]
        let pattern = VibeKeyLedPattern.pattern(for: .idle, voiceKeyTuple: voice)
        XCTAssertEqual(pattern.base.leds[0], voice)
        for led in 1...3 {
            XCTAssertEqual(pattern.base.leds[led].workType, 0)
        }
        XCTAssertEqual(pattern.base.mode, 2)
        XCTAssertNil(pattern.blinkPeriod)
    }

    func testWorkingIsKnobSolidSeven() {
        let pattern = VibeKeyLedPattern.pattern(for: .working)
        XCTAssertEqual(pattern.base.leds[3].workType, 1)
        XCTAssertEqual(pattern.base.leds[3].alwaysOnBrightness, 7)
        XCTAssertEqual(pattern.base.leds[3].workTime, 255)
        XCTAssertEqual(pattern.base.leds[1].workType, 0)
        XCTAssertEqual(pattern.base.leds[2].workType, 0)
        XCTAssertNil(pattern.blinkPeriod)
    }

    func testAttentionUsesWorkTimeTenAndLocalDowngrade() {
        let pattern = VibeKeyLedPattern.pattern(for: .attention)
        XCTAssertEqual(pattern.base.leds[1].workType, 1)
        XCTAssertEqual(pattern.base.leds[1].workTime, 10)
        XCTAssertEqual(pattern.autoOffAfter, 10.0)
    }

    func testErrorUsesGlobalAllOnFlash() {
        let pattern = VibeKeyLedPattern.pattern(for: .error)
        XCTAssertEqual(pattern.base.mode, 1)
        XCTAssertEqual(pattern.flashCount, 3)
    }

    // MARK: - Animation tables

    func testThinkingBlinkTogglesBrightnessOnly() {
        let pattern = VibeKeyLedPattern.pattern(for: .thinking)
        XCTAssertEqual(pattern.blinkPeriod, 1.2)
        XCTAssertEqual(pattern.blinkLeds, [3])
        let lit = pattern.table(atTick: 0)
        let dark = pattern.table(atTick: 1)
        XCTAssertEqual(lit.leds[3].alwaysOnBrightness, 15)
        XCTAssertEqual(dark.leds[3].alwaysOnBrightness, 0)
        // R1: workType never changes during a blink.
        XCTAssertEqual(lit.leds[3].workType, dark.leds[3].workType)
        XCTAssertEqual(lit.leds[3].workTime, dark.leds[3].workTime)
        // The diff between phases must be a single brightness frame.
        let writes = try? VibeKeyLedControl.writes(desired: dark, expected: lit)
        XCTAssertEqual(writes?.count, 1)
        XCTAssertEqual(writes?.first?.mask, VibeKeyLedControl.FieldMask.alwaysOnBrightness)
    }

    func testNotificationBlinksMiddleAndBottom() {
        let pattern = VibeKeyLedPattern.pattern(for: .notification)
        XCTAssertEqual(pattern.blinkPeriod, 0.6)
        XCTAssertEqual(pattern.blinkLeds, [1, 2])
        let lit = pattern.table(atTick: 0)
        XCTAssertEqual(lit.leds[1].alwaysOnBrightness, 15)
        XCTAssertEqual(lit.leds[2].alwaysOnBrightness, 15)
        XCTAssertEqual(lit.leds[3].workType, 0)
        let dark = pattern.table(atTick: 1)
        XCTAssertEqual(dark.leds[1].alwaysOnBrightness, 0)
        XCTAssertEqual(dark.leds[2].alwaysOnBrightness, 0)
    }

    func testSweepCyclesOneLedPerStep() {
        let pattern = VibeKeyLedPattern.pattern(for: .sweeping)
        XCTAssertEqual(pattern.sweepStep, 0.5)
        for step in 0..<6 {
            let table = pattern.table(atTick: step)
            let active = [1, 2, 3][step % 3]
            for led in 1...3 {
                XCTAssertEqual(
                    table.leds[led].alwaysOnBrightness,
                    led == active ? 15 : 0,
                    "step \(step) led \(led)"
                )
            }
        }
    }

    func testAllPatternTablesPassValidation() throws {
        for state in VibeKeyAgentState.allCases {
            let pattern = VibeKeyLedPattern.pattern(for: state)
            for tick in 0..<4 {
                try VibeKeyLedControl.validate(pattern.table(atTick: tick))
            }
        }
    }
}