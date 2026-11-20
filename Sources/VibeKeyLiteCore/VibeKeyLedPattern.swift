import Foundation

/// Agent lifecycle states rendered on the AU05 LEDs.
/// Event→state mapping follows the official ustudio-cli mappings.js
/// (docs/protocol.md); the renderer never invents its own state machine.
public enum VibeKeyAgentState: String, CaseIterable, Codable, Sendable {
    case idle
    case thinking
    case working
    case attention
    case notification
    case error
    case sweeping
    case sleeping
    case off

    /// Multi-session arbitration priority (higher wins).
    /// notification > error > sweeping > thinking > working > attention > idle/sleeping.
    public var priority: Int {
        switch self {
        case .notification: return 70
        case .error: return 60
        case .sweeping: return 50
        case .thinking: return 40
        case .working: return 30
        case .attention: return 20
        case .idle, .sleeping: return 10
        case .off: return 0
        }
    }

    /// States that must render immediately, bypassing the 200 ms debounce (R6).
    public var bypassesDebounce: Bool {
        self == .notification || self == .error
    }
}

/// Maps agent hook events to states. Tables mirror the official
/// ustudio-cli `mappings.js` for the Claude-compatible dialect, plus the
/// DSH (DeepSeek Harness) event names.
public enum VibeKeyAgentEventMapper {
    /// Claude Code / Qwen Code / Qoder / CodeBuddy / QwenWork share this table.
    public static func claudeState(forEvent event: String) -> VibeKeyAgentState? {
        switch event {
        case "SessionStart": return .idle
        case "UserPromptSubmit": return .thinking
        case "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop": return .working
        case "PostToolUseFailure", "StopFailure": return .error
        case "Stop", "TaskCompleted": return .attention
        case "Notification", "PermissionRequest": return .notification
        case "PreCompact": return .sweeping
        case "SessionEnd": return .sleeping
        default: return nil
        }
    }

    /// DSH dsh-hooks dialect: `on:` event names with optional `when:` reason.
    public static func dshState(forEvent event: String, when: String? = nil) -> VibeKeyAgentState? {
        switch event {
        case "turn/end":
            return (when == nil || when == "completed") ? .attention : .error
        case "turn/start": return .thinking
        case "tool/call": return .working
        case "approval/asked": return .notification
        case "agent/error": return .error
        case "agent/status": return .idle
        default: return nil
        }
    }

    public static func state(
        agentDialect: String,
        event: String,
        when: String? = nil
    ) -> VibeKeyAgentState? {
        switch agentDialect {
        case "dsh": return dshState(forEvent: event, when: when)
        default: return claudeState(forEvent: event)
        }
    }
}

/// Pure state→LED-table mapping. The renderer owns timers; this type only
/// answers "what should the device table look like right now".
///
/// Hardware constraints baked in (docs/protocol.md):
/// - Only LEDs 1...3 are host-driven; LED 0 keeps its stored tuple.
/// - Blinking toggles alwaysOnBrightness (single mask-0x40 frame), never
///   workType (review R1).
/// - attention uses workTime=10 so the firmware auto-extinguishes the
///   middle key after ~10 s; the renderer mirrors that with a local timer (R3).
public struct VibeKeyLedPattern: Equatable, Sendable {
    public var base: VibeKeyLedState
    /// Blink period in seconds; nil = static table.
    public var blinkPeriod: TimeInterval?
    /// LED indices whose alwaysOnBrightness toggles between lit and 0.
    public var blinkLeds: [Int]
    /// Lit brightness used during the "on" half of a blink.
    public var blinkBrightness: UInt8
    /// Sweep step interval; nil = no sweep. Cycles blinkLeds one at a time.
    public var sweepStep: TimeInterval?
    /// Global all-on flash: alternate mode 1/0 this many times, then restore.
    public var flashCount: Int?
    public var flashPeriod: TimeInterval?
    /// Local downgrade deadline for attention (R3); renderer schedules it.
    public var autoOffAfter: TimeInterval?

    public init(
        base: VibeKeyLedState,
        blinkPeriod: TimeInterval? = nil,
        blinkLeds: [Int] = [],
        blinkBrightness: UInt8 = 15,
        sweepStep: TimeInterval? = nil,
        flashCount: Int? = nil,
        flashPeriod: TimeInterval? = nil,
        autoOffAfter: TimeInterval? = nil
    ) {
        self.base = base
        self.blinkPeriod = blinkPeriod
        self.blinkLeds = blinkLeds
        self.blinkBrightness = blinkBrightness
        self.sweepStep = sweepStep
        self.flashCount = flashCount
        self.flashPeriod = flashPeriod
        self.autoOffAfter = autoOffAfter
    }

    private static func tuple(solid brightness: UInt8, workTime: UInt8 = 255) -> VibeKeyLedTuple {
        VibeKeyLedTuple(
            workType: 1, workTime: workTime, breatheLevel: 2,
            breatheBrightness: 7, alwaysOnBrightness: brightness
        )
    }

    /// Builds the pattern for a state. `voiceKeyTuple` is the LED 0 tuple
    /// read back from the device (never modified by the host).
    ///
    /// `thinkingLeds` selects which LEDs carry the thinking slow blink.
    /// **Single wiring point for the pending thinking-LED observation**:
    /// the default `[3]` (knob) is PROVISIONAL — the 2026-11-20 clean
    /// sequence showed middle+bottom blinking instead, while the earlier
    /// isolated test confirmed the knob. Until the user's isolated
    /// observation settles it, callers keep the default; once settled,
    /// change ONLY `VibeKeyLedRenderEngine.thinkingLeds` (one constant).
    public static func pattern(
        for state: VibeKeyAgentState,
        voiceKeyTuple: VibeKeyLedTuple = VibeKeyLedState.baseline.leds[0],
        thinkingLeds: [Int] = [3]
    ) -> VibeKeyLedPattern {
        let off = VibeKeyLedTuple.baselineOff
        func table(_ l1: VibeKeyLedTuple, _ l2: VibeKeyLedTuple, _ l3: VibeKeyLedTuple,
                   mode: UInt8 = 2) -> VibeKeyLedState {
            VibeKeyLedState(mode: mode, allOnBrightness: 15,
                            leds: [voiceKeyTuple, l1, l2, l3])
        }
        switch state {
        case .idle, .sleeping, .off:
            return VibeKeyLedPattern(base: table(off, off, off))
        case .thinking:
            // Slow blink 1.2 s: solid wt=1, brightness toggles 15/0 (R1).
            // Lit LEDs come from thinkingLeds; all others stay off.
            var tuples: [VibeKeyLedTuple] = [off, off, off]
            for led in thinkingLeds where tuples.indices.contains(led - 1) {
                tuples[led - 1] = tuple(solid: 15)
            }
            return VibeKeyLedPattern(
                base: table(tuples[0], tuples[1], tuples[2]),
                blinkPeriod: 1.2, blinkLeds: thinkingLeds
            )
        case .working:
            return VibeKeyLedPattern(base: table(off, off, tuple(solid: 7)))
        case .attention:
            // Middle key lit with workTime=10: firmware auto-off after ~10 s.
            return VibeKeyLedPattern(
                base: table(tuple(solid: 15, workTime: 10), off, off),
                autoOffAfter: 10.0
            )
        case .notification:
            // Middle + bottom fast blink 0.6 s (R2).
            return VibeKeyLedPattern(
                base: table(tuple(solid: 15), tuple(solid: 15), off),
                blinkPeriod: 0.6, blinkLeds: [1, 2]
            )
        case .error:
            // Global all-on flash ×3, then the renderer restores the snapshot.
            return VibeKeyLedPattern(
                base: table(off, off, off, mode: 1),
                flashCount: 3, flashPeriod: 0.4
            )
        case .sweeping:
            // Three-LED chase, 0.5 s per step (R5).
            return VibeKeyLedPattern(
                base: table(tuple(solid: 15), off, off),
                blinkLeds: [1, 2, 3], sweepStep: 0.5
            )
        }
    }

    /// The table for a given animation phase. `tick` counts half-periods for
    /// blink, or steps for sweep. Static patterns ignore it.
    public func table(atTick tick: Int) -> VibeKeyLedState {
        var result = base
        if let _ = blinkPeriod, !blinkLeds.isEmpty {
            let lit = tick % 2 == 0
            for led in blinkLeds where result.leds.indices.contains(led) {
                result.leds[led].alwaysOnBrightness = lit ? blinkBrightness : 0
            }
        }
        if let _ = sweepStep, !blinkLeds.isEmpty {
            let active = blinkLeds[tick % blinkLeds.count]
            for led in blinkLeds where result.leds.indices.contains(led) {
                result.leds[led].alwaysOnBrightness = led == active ? blinkBrightness : 0
                result.leds[led].workType = 1
                result.leds[led].workTime = 255
            }
        }
        return result
    }
}