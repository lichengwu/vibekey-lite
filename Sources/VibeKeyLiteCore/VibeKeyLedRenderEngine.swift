import Foundation

/// Pure rendering state machine for the AU05 agent lights
/// (docs/m2-led-design.md §2.1 R1–R7). No timers, no HID: the host drives it
/// with a monotonic clock (`now`) and delivers the emitted write plans.
/// Every timing rule is therefore unit-testable with an injected clock.
///
/// Rules implemented:
/// - R1/R2 blinking toggles brightness only; thinking 1.2 s, notification 0.6 s
/// - R3 attention downgrades to idle locally 10 s after entry
/// - R4 error snapshots the pre-error state; after 3 flashes the snapshot is
///   fully rewritten. A non-error event during the flash preempts it and
///   renders immediately (the snapshot is discarded, not restored later).
/// - R5 sweep steps every 0.5 s
/// - R6 notification/error bypass the 200 ms debounce; others coalesce
///   (latest wins) through VibeKeyAppActivationDebouncer-style generations
/// - R7 three consecutive write failures suspend; events park in `pending`;
///   `resume(now:)` replays pending-or-current with a fresh device baseline
public struct VibeKeyLedRenderEngine {
    public struct WritePlan: Equatable, Sendable {
        public var desired: VibeKeyLedState
        public var expected: VibeKeyLedState
        /// When true the host must not coalesce or drop this plan: it is a
        /// state-entry render or an animation step whose device effect is
        /// required even if the table equals the last confirmed one.
        public var force: Bool

        public init(desired: VibeKeyLedState, expected: VibeKeyLedState, force: Bool = false) {
            self.desired = desired
            self.expected = expected
            self.force = force
        }
    }

    public static let debounceInterval: TimeInterval = 0.2
    public static let failureThreshold = 3

    public private(set) var currentState: VibeKeyAgentState = .idle
    public private(set) var deviceState: VibeKeyLedState
    public private(set) var suspended = false
    public private(set) var consecutiveFailures = 0
    /// State requested while suspended or mid-write; replayed on completion.
    public private(set) var pendingState: VibeKeyAgentState?
    public private(set) var enabled = true

    private var pattern: VibeKeyLedPattern
    private var animationTick = 0
    private var nextAnimationAt: TimeInterval?
    private var attentionDowngradeAt: TimeInterval?
    private var preErrorSnapshot: VibeKeyAgentState?
    private var flashStepsRemaining = 0
    private var flashOn = false
    private var nextFlashAt: TimeInterval?
    private var debounceDeadline: TimeInterval?
    private var debounceGeneration: UInt64 = 0
    private var debounceTarget: VibeKeyAgentState?
    private var writeInFlight = false
    /// Logical state reset after a failed write so retries are not deduped.
    /// Kept separate from `currentState` (the publicly reported state).
    private var lastRenderedState: VibeKeyAgentState?

    public init(deviceState: VibeKeyLedState = .baseline) {
        self.deviceState = deviceState
        self.pattern = VibeKeyLedPattern.pattern(for: .idle, voiceKeyTuple: deviceState.leds[0])
    }

    // MARK: - Input

    /// Requests a state. R6: notification/error render immediately; other
    /// states coalesce within the debounce window (latest wins).
    public mutating func request(_ state: VibeKeyAgentState, now: TimeInterval) -> [WritePlan] {
        guard enabled else { return [] }
        if state.bypassesDebounce {
            cancelDebounce()
            return transition(to: state, now: now, force: false)
        }
        debounceGeneration &+= 1
        debounceTarget = state
        debounceDeadline = now + Self.debounceInterval
        return []
    }

    /// Advances all deadlines. Call periodically (e.g. every animation tick
    /// or on a coarse host timer). Returns any writes that became due.
    public mutating func tick(now: TimeInterval) -> [WritePlan] {
        guard enabled else { return [] }
        var plans: [WritePlan] = []

        if let deadline = debounceDeadline, now >= deadline {
            let target = debounceTarget
            cancelDebounce()
            if let target {
                plans += transition(to: target, now: now, force: false)
            }
        }

        // R3: attention auto-downgrade mirrors the firmware workTime=10 off.
        if let deadline = attentionDowngradeAt, now >= deadline {
            attentionDowngradeAt = nil
            if currentState == .attention {
                plans += transition(to: .idle, now: now, force: false)
            }
        }

        // R4: error flash sequence.
        if currentState == .error, let deadline = nextFlashAt, now >= deadline {
            plans += advanceFlash(now: now)
        }

        // R1/R5: blink / sweep animation.
        if !writeInFlight, !suspended,
           let deadline = nextAnimationAt, now >= deadline,
           pattern.blinkPeriod != nil || pattern.sweepStep != nil {
            animationTick += 1
            let interval = pattern.sweepStep ?? (pattern.blinkPeriod! / 2)
            nextAnimationAt = deadline + interval
            plans += emit(pattern.table(atTick: animationTick), force: true)
        }
        return plans
    }

    /// Reports a write result. R7: three consecutive failures suspend.
    /// `renderedState` is the state the failed/succeeded plan belonged to;
    /// on failure the engine rolls its logical state back so the same state
    /// can be requested again (the device never received the table).
    public mutating func writeCompleted(
        success: Bool,
        now: TimeInterval,
        renderedState: VibeKeyAgentState? = nil
    ) -> [WritePlan] {
        writeInFlight = false
        guard success else {
            consecutiveFailures += 1
            if consecutiveFailures >= Self.failureThreshold {
                suspended = true
                nextAnimationAt = nil
                nextFlashAt = nil
            } else {
                // Roll back the dedup marker so a retry is not swallowed.
                // currentState stays reported as-is for observers.
                if let renderedState, renderedState == lastRenderedState {
                    lastRenderedState = nil
                    nextAnimationAt = nil
                    attentionDowngradeAt = nil
                }
                if let pending = pendingState {
                    pendingState = nil
                    return transition(to: pending, now: now, force: false)
                }
            }
            return []
        }
        consecutiveFailures = 0
        if let pending = pendingState {
            pendingState = nil
            if pending != currentState {
                return transition(to: pending, now: now, force: false)
            }
        }
        return []
    }

    /// The host must set the diff baseline to the written table on success
    /// (the engine cannot know which plan the write belonged to).
    public mutating func confirmDeviceState(_ state: VibeKeyLedState) {
        deviceState = state
    }

    /// R7 recovery: device reachable again. Replays pending-or-current.
    public mutating func resume(now: TimeInterval, deviceState fresh: VibeKeyLedState) -> [WritePlan] {
        deviceState = fresh
        suspended = false
        consecutiveFailures = 0
        enabled = true
        let target = pendingState ?? currentState
        pendingState = nil
        return transition(to: target, now: now, force: true)
    }

    /// Vendor (Ulanzi Studio) took over: stop emitting until resume().
    public mutating func suspendForVendor() {
        suspended = true
        nextAnimationAt = nil
        nextFlashAt = nil
        cancelDebounce()
    }

    /// App quit / manual off: restore the factory baseline.
    public mutating func shutdown() -> WritePlan {
        enabled = false
        nextAnimationAt = nil
        nextFlashAt = nil
        attentionDowngradeAt = nil
        cancelDebounce()
        return WritePlan(desired: .baseline, expected: deviceState)
    }

    // MARK: - Transitions

    private mutating func transition(
        to state: VibeKeyAgentState,
        now: TimeInterval,
        force: Bool
    ) -> [WritePlan] {
        guard enabled else { return [] }
        if suspended || writeInFlight {
            pendingState = state
            return []
        }
        if state == lastRenderedState, !force { return [] }

        nextAnimationAt = nil
        attentionDowngradeAt = nil

        // R4: snapshot before entering error; a non-error event during the
        // flash preempts it (snapshot discarded — the new event wins).
        if state == .error {
            if currentState != .error {
                preErrorSnapshot = currentState
            }
        } else {
            nextFlashAt = nil
            flashStepsRemaining = 0
            preErrorSnapshot = nil
        }

        currentState = state
        lastRenderedState = state
        pattern = VibeKeyLedPattern.pattern(for: state, voiceKeyTuple: deviceState.leds[0])
        animationTick = 0

        if let flashCount = pattern.flashCount, flashCount > 0 {
            flashStepsRemaining = flashCount * 2
            flashOn = true
            nextFlashAt = now + (pattern.flashPeriod ?? 0.4)
            return emit(pattern.base, force: true) // mode 1, first flash
        }

        var plans = emit(pattern.table(atTick: 0), force: true)
        if let sweep = pattern.sweepStep {
            nextAnimationAt = now + sweep
        } else if let blink = pattern.blinkPeriod {
            nextAnimationAt = now + blink / 2
        }
        if let delay = pattern.autoOffAfter {
            attentionDowngradeAt = now + delay
        }
        return plans
    }

    private mutating func advanceFlash(now: TimeInterval) -> [WritePlan] {
        flashStepsRemaining -= 1
        if flashStepsRemaining <= 0 {
            // R4: full rewrite of the pre-error snapshot, not just mode 2.
            let snapshot = preErrorSnapshot ?? .idle
            preErrorSnapshot = nil
            nextFlashAt = nil
            lastRenderedState = nil // allow re-transition into the snapshot
            return transition(to: snapshot, now: now, force: true)
        }
        flashOn.toggle()
        var table = pattern.base
        table.mode = flashOn ? 1 : 0
        nextFlashAt = now + (pattern.flashPeriod ?? 0.4)
        return emit(table, force: true)
    }

    private mutating func emit(_ desired: VibeKeyLedState, force: Bool = false) -> [WritePlan] {
        guard !suspended else { return [] }
        writeInFlight = true
        return [WritePlan(desired: desired, expected: deviceState, force: force)]
    }

    private mutating func cancelDebounce() {
        debounceDeadline = nil
        debounceTarget = nil
    }
}