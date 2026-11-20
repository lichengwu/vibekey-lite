import Foundation
import OSLog
import VibeKeyLiteCore

/// Renders agent states onto the AU05 LEDs. Owns all animation timers.
/// Main-queue only; the listener serializes actual HID writes.
///
/// Behavior rules from docs/m2-led-design.md §2.1:
/// - R1 blinking toggles brightness only (single mask-0x40 frame per tick)
/// - R3 attention downgrades to idle locally after 10 s
/// - R4 error restores the pre-error snapshot after flashing
/// - R6 notification/error bypass the 200 ms debounce
/// - R7 three consecutive write failures suspend rendering until resume()
final class LedRenderer {
    private let apply: (VibeKeyLedState, VibeKeyLedState, @escaping (Error?) -> Void) -> Void
    private let readState: (@escaping (VibeKeyLedState?, Error?) -> Void) -> Void
    private let logger = Logger(subsystem: "io.github.arumwu.VibeKeyLite", category: "LED")

    /// Last table believed to be on the device (diff baseline).
    private var deviceState: VibeKeyLedState
    private var currentState: VibeKeyAgentState = .idle
    private var currentPattern: VibeKeyLedPattern?
    private var animationTimer: Timer?
    private var animationTick = 0
    private var debounceWorkItem: DispatchWorkItem?
    private var attentionWorkItem: DispatchWorkItem?
    private var preErrorSnapshot: (state: VibeKeyAgentState, pattern: VibeKeyLedPattern)?
    private var flashRemaining = 0
    private var flashOn = false
    private var consecutiveFailures = 0
    private var suspended = false
    private var applying = false
    private var pendingState: VibeKeyAgentState?
    private var enabled = true

    init(
        initialDeviceState: VibeKeyLedState = .baseline,
        apply: @escaping (VibeKeyLedState, VibeKeyLedState, @escaping (Error?) -> Void) -> Void,
        readState: @escaping (@escaping (VibeKeyLedState?, Error?) -> Void) -> Void
    ) {
        self.deviceState = initialDeviceState
        self.apply = apply
        self.readState = readState
    }

    var state: VibeKeyAgentState { currentState }
    var isSuspended: Bool { suspended }

    /// Refreshes the diff baseline from a device GET (e.g. after reconnect).
    func syncDeviceState(_ state: VibeKeyLedState) {
        deviceState = state
    }

    /// Requests a state change. Debounced unless the state bypasses it (R6).
    func request(_ state: VibeKeyAgentState) {
        guard enabled else { return }
        debounceWorkItem?.cancel()
        if state.bypassesDebounce {
            transition(to: state)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.transition(to: state)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    /// Disables rendering and restores the factory baseline (app quit / off).
    func shutdown(completion: (() -> Void)? = nil) {
        enabled = false
        cancelAllTimers()
        let baseline = VibeKeyLedState.baseline
        apply(baseline, deviceState) { [weak self] error in
            if error == nil { self?.deviceState = baseline }
            completion?()
        }
    }

    /// Re-enables after suspend (device wake / Studio exit) and replays state.
    func resume() {
        suspended = false
        consecutiveFailures = 0
        enabled = true
        readState { [weak self] state, _ in
            guard let self else { return }
            if let state { self.deviceState = state }
            self.transition(to: self.currentState, force: true)
        }
    }

    /// Studio took over the device: stop writing until it exits.
    func suspendForVendor() {
        suspended = true
        cancelAnimation()
        logger.notice("LED rendering suspended while Ulanzi Studio runs")
    }

    // MARK: - Transitions

    private func transition(to state: VibeKeyAgentState, force: Bool = false) {
        guard enabled else { return }
        if suspended {
            pendingState = state
            return
        }
        if applying {
            pendingState = state
            return
        }
        if state == currentState, !force { return }

        cancelAnimation()
        attentionWorkItem?.cancel()
        attentionWorkItem = nil

        // R4: snapshot before error so the flash can restore it.
        if state == .error, currentState != .error {
            preErrorSnapshot = (currentState, currentPattern ?? VibeKeyLedPattern.pattern(for: currentState))
        }

        currentState = state
        let pattern = VibeKeyLedPattern.pattern(for: state, voiceKeyTuple: deviceState.leds[0])
        currentPattern = pattern
        animationTick = 0

        if let flashCount = pattern.flashCount, flashCount > 0 {
            flashRemaining = flashCount * 2
            flashOn = true
            writeTable(pattern.base) // mode 1 first flash
            scheduleFlash(pattern: pattern)
            return
        }

        writeTable(pattern.table(atTick: 0))
        startAnimationIfNeeded(pattern: pattern)

        // R3: mirror the firmware's workTime=10 auto-off locally.
        if let delay = pattern.autoOffAfter {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.currentState == .attention else { return }
                self.transition(to: .idle)
            }
            attentionWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func startAnimationIfNeeded(pattern: VibeKeyLedPattern) {
        let interval: TimeInterval?
        if let sweep = pattern.sweepStep {
            interval = sweep
        } else if let blink = pattern.blinkPeriod {
            interval = blink / 2
        } else {
            interval = nil
        }
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.animationStep()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func animationStep() {
        guard let pattern = currentPattern, !applying, !suspended else { return }
        animationTick += 1
        writeTable(pattern.table(atTick: animationTick))
    }

    private func scheduleFlash(pattern: VibeKeyLedPattern) {
        let period = pattern.flashPeriod ?? 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + period) { [weak self] in
            guard let self, self.currentState == .error else { return }
            self.flashRemaining -= 1
            if self.flashRemaining <= 0 {
                // R4: restore the pre-error state with a full rewrite.
                let snapshot = self.preErrorSnapshot ?? (.idle, VibeKeyLedPattern.pattern(for: .idle))
                self.preErrorSnapshot = nil
                self.currentState = .idle // allow re-transition
                self.transition(to: snapshot.state, force: true)
                return
            }
            self.flashOn.toggle()
            var table = pattern.base
            table.mode = self.flashOn ? 1 : 0
            self.writeTable(table)
            self.scheduleFlash(pattern: pattern)
        }
    }

    // MARK: - Write plumbing

    private func writeTable(_ desired: VibeKeyLedState) {
        guard !suspended else { return }
        applying = true
        let expected = deviceState
        apply(desired, expected) { [weak self] error in
            guard let self else { return }
            self.applying = false
            if let error {
                self.consecutiveFailures += 1
                self.logger.error("LED write failed (\(self.consecutiveFailures)): \(error.localizedDescription, privacy: .public)")
                // R7: suspend after three consecutive failures.
                if self.consecutiveFailures >= 3 {
                    self.suspended = true
                    self.cancelAnimation()
                    self.logger.notice("LED rendering suspended until device wake")
                }
                return
            }
            self.consecutiveFailures = 0
            self.deviceState = desired
            if let pending = self.pendingState {
                self.pendingState = nil
                if pending != self.currentState {
                    self.transition(to: pending)
                }
            }
        }
    }

    private func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func cancelAllTimers() {
        cancelAnimation()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        attentionWorkItem?.cancel()
        attentionWorkItem = nil
    }
}