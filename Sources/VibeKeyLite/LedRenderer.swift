import Foundation
import OSLog
import VibeKeyLiteCore

/// Thin App-side shell over the pure VibeKeyLedRenderEngine.
/// Owns only timers and the HID write plumbing; every rendering rule
/// (R1–R7, debounce, flash, downgrade, suspend/replay) lives in the Engine
/// and is unit-tested there with an injected clock.
///
/// Thinking LED placement is confirmed (knob, user observation 2026-11-21);
/// the single wiring point is `VibeKeyLedRenderEngine.thinkingLeds` —
/// any future placement change touches only that constant.
final class LedRenderer {
    private let apply: (VibeKeyLedState, VibeKeyLedState, Bool, @escaping (Error?) -> Void) -> Void
    private let readState: (@escaping (VibeKeyLedState?, Error?) -> Void) -> Void
    private let logger = Logger(subsystem: "io.github.arumwu.VibeKeyLite", category: "LED")

    private var engine: VibeKeyLedRenderEngine
    /// Coarse pump: drives debounce/flash/downgrade/animation deadlines.
    private var tickTimer: Timer?
    private var suspendRetryTimer: Timer?
    /// State the in-flight write belongs to (for Engine failure rollback).
    private var inFlightState: VibeKeyAgentState?

    private static let tickInterval: TimeInterval = 0.05

    init(
        initialDeviceState: VibeKeyLedState = .baseline,
        apply: @escaping (VibeKeyLedState, VibeKeyLedState, Bool, @escaping (Error?) -> Void) -> Void,
        readState: @escaping (@escaping (VibeKeyLedState?, Error?) -> Void) -> Void
    ) {
        self.engine = VibeKeyLedRenderEngine(deviceState: initialDeviceState)
        self.apply = apply
        self.readState = readState
        startTickTimer()
    }

    var state: VibeKeyAgentState { engine.currentState }
    var isSuspended: Bool { engine.suspended }

    /// Refreshes the diff baseline from a device GET (e.g. after reconnect).
    func syncDeviceState(_ state: VibeKeyLedState) {
        engine.confirmDeviceState(state)
    }

    /// Requests a state change. Debounce/bypass rules live in the Engine.
    func request(_ state: VibeKeyAgentState) {
        let plans = engine.request(state, now: Self.now())
        deliver(plans)
    }

    /// Disables rendering and restores the factory baseline (app quit / off).
    func shutdown(completion: (() -> Void)? = nil) {
        tickTimer?.invalidate()
        tickTimer = nil
        suspendRetryTimer?.invalidate()
        suspendRetryTimer = nil
        let plan = engine.shutdown()
        apply(plan.desired, plan.expected, true) { [weak self] error in
            if error == nil { self?.engine.confirmDeviceState(plan.desired) }
            completion?()
        }
    }

    /// Re-enables after suspend (device wake / Studio exit) and replays state.
    func resume() {
        readState { [weak self] state, _ in
            guard let self else { return }
            let fresh = state ?? self.engine.deviceState
            let plans = self.engine.resume(now: Self.now(), deviceState: fresh)
            self.deliver(plans)
        }
    }

    /// Studio took over the device: stop writing until it exits.
    func suspendForVendor() {
        engine.suspendForVendor()
        suspendRetryTimer?.invalidate()
        suspendRetryTimer = nil
        logger.notice("LED rendering suspended while Ulanzi Studio runs")
    }

    // MARK: - Timers

    private func startTickTimer() {
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let plans = self.engine.tick(now: Self.now())
            self.deliver(plans)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// R7 self-heal (8fd5ef5 behavior, kept): while suspended for write
    /// failures, probe the device every 10 s; a successful GET replays
    /// pending-or-current state through the Engine.
    private func scheduleSuspendRetryIfNeeded() {
        guard engine.suspended, suspendRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.engine.suspended else { return }
            self.readState { [weak self] state, error in
                guard let self, self.engine.suspended else { return }
                guard error == nil, let state else { return }
                self.logger.notice("LED device reachable again; resuming")
                self.suspendRetryTimer?.invalidate()
                self.suspendRetryTimer = nil
                let plans = self.engine.resume(now: Self.now(), deviceState: state)
                self.deliver(plans)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        suspendRetryTimer = timer
    }

    // MARK: - Write plumbing

    private func deliver(_ plans: [VibeKeyLedRenderEngine.WritePlan]) {
        // The Engine emits at most one plan per call (single in-flight write).
        guard let plan = plans.first else { return }
        inFlightState = engine.currentState
        apply(plan.desired, plan.expected, plan.force) { [weak self] error in
            guard let self else { return }
            let rendered = self.inFlightState
            self.inFlightState = nil
            if let error {
                self.logger.error("LED write failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self.engine.confirmDeviceState(plan.desired)
            }
            let followUp = self.engine.writeCompleted(
                success: error == nil, now: Self.now(), renderedState: rendered
            )
            self.scheduleSuspendRetryIfNeeded()
            self.deliver(followUp)
        }
    }

    private static func now() -> TimeInterval {
        Date().timeIntervalSince1970
    }
}