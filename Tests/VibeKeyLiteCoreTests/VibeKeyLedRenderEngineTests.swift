import XCTest
@testable import VibeKeyLiteCore

/// Drives VibeKeyLedRenderEngine with an injected clock and a fake device.
/// Every R1–R7 rule is asserted against emitted WritePlans, never hardware.
final class VibeKeyLedRenderEngineTests: XCTestCase {
    private var engine = VibeKeyLedRenderEngine()
    private var now: TimeInterval = 1000

    override func setUp() {
        super.setUp()
        engine = VibeKeyLedRenderEngine()
        now = 1000
    }

    /// Completes the in-flight write successfully and confirms the table.
    private func completeWrite(_ plans: [VibeKeyLedRenderEngine.WritePlan]) {
        guard let last = plans.last else { return }
        engine.confirmDeviceState(last.desired)
        _ = engine.writeCompleted(success: true, now: now)
    }

    private func requestAndSettle(_ state: VibeKeyAgentState) -> [VibeKeyLedRenderEngine.WritePlan] {
        var plans = engine.request(state, now: now)
        if plans.isEmpty {
            now += VibeKeyLedRenderEngine.debounceInterval
            plans = engine.tick(now: now)
        }
        completeWrite(plans)
        return plans
    }

    // MARK: - Static states and frame content

    func testWorkingEmitsKnobSolidPlan() {
        let plans = requestAndSettle(.working)
        XCTAssertEqual(plans.count, 1)
        let desired = plans[0].desired
        XCTAssertEqual(desired.mode, 2)
        XCTAssertEqual(desired.leds[3].workType, 1)
        XCTAssertEqual(desired.leds[3].alwaysOnBrightness, 7)
        XCTAssertEqual(desired.leds[3].workTime, 255)
        XCTAssertEqual(engine.currentState, .working)
    }

    func testIdleTurnsHostLedsOff() {
        _ = requestAndSettle(.working)
        let plans = requestAndSettle(.idle)
        for led in 1...3 {
            XCTAssertEqual(plans[0].desired.leds[led].workType, 0)
        }
    }

    func testSameStateRequestEmitsNothing() {
        _ = requestAndSettle(.working)
        let plans = engine.request(.working, now: now)
        XCTAssertTrue(plans.isEmpty)
        now += 1
        XCTAssertTrue(engine.tick(now: now).isEmpty)
    }

    // MARK: - R6 debounce and bypass

    func testNonUrgentStateIsDebounced() {
        let immediate = engine.request(.working, now: now)
        XCTAssertTrue(immediate.isEmpty, "working must wait for the debounce window")
        now += 0.19
        XCTAssertTrue(engine.tick(now: now).isEmpty)
        now += 0.02
        let plans = engine.tick(now: now)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(engine.currentState, .working)
    }

    func testDebounceCoalescesLatestWins() {
        _ = engine.request(.working, now: now)
        now += 0.1
        _ = engine.request(.thinking, now: now)
        now += VibeKeyLedRenderEngine.debounceInterval
        let plans = engine.tick(now: now)
        XCTAssertEqual(engine.currentState, .thinking, "latest request must win")
        XCTAssertEqual(plans.count, 1)
    }

    func testNotificationBypassesDebounce() {
        let plans = engine.request(.notification, now: now)
        XCTAssertEqual(plans.count, 1, "notification must render immediately")
        XCTAssertEqual(engine.currentState, .notification)
    }

    func testErrorBypassesDebounce() {
        let plans = engine.request(.error, now: now)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(engine.currentState, .error)
        XCTAssertEqual(plans[0].desired.mode, 1)
    }

    func testUrgentRequestCancelsPendingDebounce() {
        _ = engine.request(.working, now: now)
        _ = engine.request(.notification, now: now)
        completeWrite([VibeKeyLedRenderEngine.WritePlan](
            engine.request(.notification, now: now)
        ))
        now += 1
        _ = engine.tick(now: now)
        XCTAssertEqual(engine.currentState, .notification,
                       "stale debounced working must not fire after notification")
    }

    // MARK: - R1/R2 blink timing (brightness-only frames)

    func testThinkingBlinkPeriodAndBrightnessOnlyFrames() {
        let entry = requestAndSettle(.thinking)
        XCTAssertEqual(entry[0].desired.leds[3].alwaysOnBrightness, 15)

        // Half period = 0.6 s: first toggle dark.
        now += 0.6
        let dark = engine.tick(now: now)
        XCTAssertEqual(dark.count, 1)
        XCTAssertEqual(dark[0].desired.leds[3].alwaysOnBrightness, 0)
        XCTAssertEqual(dark[0].desired.leds[3].workType,
                       entry[0].desired.leds[3].workType, "R1: workType must not change")
        // The diff must be a single brightness frame.
        let writes = try? VibeKeyLedControl.writes(
            desired: dark[0].desired, expected: entry[0].desired
        )
        XCTAssertEqual(writes?.count, 1)
        XCTAssertEqual(writes?.first?.mask, VibeKeyLedControl.FieldMask.alwaysOnBrightness)
        completeWrite(dark)

        // Next half period: lit again.
        now += 0.6
        let lit = engine.tick(now: now)
        XCTAssertEqual(lit[0].desired.leds[3].alwaysOnBrightness, 15)
        completeWrite(lit)
    }

    func testNotificationBlinksBothKeysAt06s() {
        let entry = requestAndSettle(.notification)
        XCTAssertEqual(entry[0].desired.leds[1].alwaysOnBrightness, 15)
        XCTAssertEqual(entry[0].desired.leds[2].alwaysOnBrightness, 15)
        now += 0.3
        let dark = engine.tick(now: now)
        XCTAssertEqual(dark[0].desired.leds[1].alwaysOnBrightness, 0)
        XCTAssertEqual(dark[0].desired.leds[2].alwaysOnBrightness, 0)
        XCTAssertEqual(dark[0].desired.leds[3].workType, 0, "knob stays off")
    }

    // MARK: - R5 sweep timing

    func testSweepStepsEvery05s() {
        let entry = requestAndSettle(.sweeping)
        XCTAssertEqual(entry[0].desired.leds[1].alwaysOnBrightness, 15)
        completeWrite(entry)
        for step in 1...4 {
            now += 0.5
            let plans = engine.tick(now: now)
            XCTAssertEqual(plans.count, 1, "step \(step)")
            let active = [1, 2, 3][step % 3]
            for led in 1...3 {
                XCTAssertEqual(
                    plans[0].desired.leds[led].alwaysOnBrightness,
                    led == active ? 15 : 0,
                    "step \(step) led \(led)"
                )
            }
            completeWrite(plans)
        }
    }

    // MARK: - R3 attention downgrade

    func testAttentionDowngradesToIdleAfter10s() {
        let entry = requestAndSettle(.attention)
        XCTAssertEqual(entry[0].desired.leds[1].workTime, 10)
        now += 9.9
        XCTAssertTrue(engine.tick(now: now).isEmpty)
        now += 0.2
        let plans = engine.tick(now: now)
        XCTAssertEqual(engine.currentState, .idle)
        XCTAssertEqual(plans.count, 1)
        for led in 1...3 {
            XCTAssertEqual(plans[0].desired.leds[led].workType, 0)
        }
    }

    func testAttentionDowngradeCancelledByNewState() {
        _ = requestAndSettle(.attention)
        _ = requestAndSettle(.working)
        now += 15
        _ = engine.tick(now: now)
        XCTAssertEqual(engine.currentState, .working,
                       "downgrade must not fire after leaving attention")
    }

    // MARK: - R4 error flash and snapshot

    /// Runs the full 3-flash sequence, completing each write.
    private func runErrorFlash() -> [VibeKeyLedRenderEngine.WritePlan] {
        var all: [VibeKeyLedRenderEngine.WritePlan] = []
        for _ in 0..<6 {
            now += 0.4
            let plans = engine.tick(now: now)
            all += plans
            completeWrite(plans)
            if engine.currentState != .error { break }
        }
        return all
    }

    func testErrorFlashesThreeTimesThenRestoresSnapshot() {
        _ = requestAndSettle(.working)
        let entry = engine.request(.error, now: now)
        XCTAssertEqual(entry[0].desired.mode, 1)
        completeWrite(entry)

        let flashPlans = runErrorFlash()
        // mode alternates 0,1,0,1,0 then the restore write.
        let modes = flashPlans.map(\.desired.mode)
        XCTAssertEqual(Array(modes.prefix(5)), [0, 1, 0, 1, 0])
        XCTAssertEqual(engine.currentState, .working, "must restore pre-error state")
        // R4: the restore is a full table rewrite, not just mode 2.
        let restore = flashPlans.last!
        XCTAssertEqual(restore.desired.leds[3].workType, 1)
        XCTAssertEqual(restore.desired.leds[3].alwaysOnBrightness, 7)
        XCTAssertEqual(restore.desired.leds[3].workTime, 255)
        XCTAssertTrue(restore.force)
    }

    func testErrorFromIdleRestoresIdle() {
        _ = requestAndSettle(.idle)
        completeWrite(engine.request(.error, now: now))
        _ = runErrorFlash()
        XCTAssertEqual(engine.currentState, .idle)
    }

    func testNewEventDuringErrorFlashPreemptsRestore() {
        _ = requestAndSettle(.working)
        completeWrite(engine.request(.error, now: now))
        now += 0.4
        completeWrite(engine.tick(now: now)) // one flash step done

        // Notification arrives mid-flash: must win immediately, and the
        // working snapshot must NOT be restored afterwards.
        let plans = engine.request(.notification, now: now)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(engine.currentState, .notification)
        completeWrite(plans)
        now += 5
        _ = engine.tick(now: now)
        XCTAssertEqual(engine.currentState, .notification,
                       "discarded snapshot must not resurrect working")
    }

    func testRepeatedErrorDoesNotOverwriteSnapshotWithItself() {
        _ = requestAndSettle(.working)
        completeWrite(engine.request(.error, now: now))
        // A second error request while already in error keeps the snapshot.
        _ = engine.request(.error, now: now)
        _ = runErrorFlash()
        XCTAssertEqual(engine.currentState, .working)
    }

    // MARK: - R7 failure suspend and replay

    func testThreeConsecutiveFailuresSuspend() {
        _ = requestAndSettle(.working)
        for attempt in 1...3 {
            _ = engine.request(.idle, now: now)
            now += VibeKeyLedRenderEngine.debounceInterval
            let due = engine.tick(now: now)
            XCTAssertFalse(due.isEmpty, "attempt \(attempt) should emit before suspend")
            _ = engine.writeCompleted(success: false, now: now, renderedState: .idle)
        }
        XCTAssertTrue(engine.suspended)
        // Further requests park instead of emitting.
        let parked = engine.request(.notification, now: now)
        XCTAssertTrue(parked.isEmpty)
        XCTAssertEqual(engine.pendingState, .notification)
    }

    func testSuccessResetsFailureCount() {
        _ = requestAndSettle(.working)
        _ = engine.request(.idle, now: now)
        now += 0.2
        _ = engine.tick(now: now)
        _ = engine.writeCompleted(success: false, now: now)
        _ = engine.writeCompleted(success: false, now: now)
        XCTAssertEqual(engine.consecutiveFailures, 2)
        // A successful write resets the streak.
        let plans = engine.request(.working, now: now)
        now += 0.2
        let due = plans.isEmpty ? engine.tick(now: now) : plans
        completeWrite(due)
        XCTAssertEqual(engine.consecutiveFailures, 0)
        XCTAssertFalse(engine.suspended)
    }

    func testResumeReplaysPendingState() {
        _ = requestAndSettle(.working)
        for _ in 1...3 {
            _ = engine.request(.idle, now: now)
            now += 0.2
            _ = engine.tick(now: now)
            _ = engine.writeCompleted(success: false, now: now)
        }
        _ = engine.request(.notification, now: now)
        XCTAssertTrue(engine.suspended)

        now += 10
        let plans = engine.resume(now: now, deviceState: .baseline)
        XCTAssertFalse(engine.suspended)
        XCTAssertEqual(engine.currentState, .notification,
                       "pending event during suspend must replay first")
        XCTAssertEqual(plans.count, 1)
    }

    func testResumeWithoutPendingReplaysCurrent() {
        _ = requestAndSettle(.working)
        for _ in 1...3 {
            _ = engine.request(.working, now: now)
            now += 0.2
            _ = engine.tick(now: now)
            _ = engine.writeCompleted(success: false, now: now)
        }
        // Same-state requests emit nothing, so drive failures via idle ticks.
        // (If not suspended yet, force three failing idle writes.)
        if !engine.suspended {
            for _ in 1...3 {
                _ = engine.request(.idle, now: now)
                now += 0.2
                _ = engine.tick(now: now)
                _ = engine.writeCompleted(success: false, now: now)
            }
        }
        XCTAssertTrue(engine.suspended)
        let plans = engine.resume(now: now, deviceState: .baseline)
        XCTAssertEqual(plans.count, 1, "current state must re-render after resume")
        XCTAssertTrue(plans[0].force)
    }

    // MARK: - Vendor suspend / shutdown

    func testVendorSuspendStopsAnimationUntilResume() {
        _ = requestAndSettle(.thinking)
        engine.suspendForVendor()
        now += 5
        XCTAssertTrue(engine.tick(now: now).isEmpty)
        let plans = engine.resume(now: now, deviceState: .baseline)
        XCTAssertEqual(engine.currentState, .thinking)
        XCTAssertEqual(plans.count, 1)
    }

    func testShutdownEmitsBaselineRestore() {
        _ = requestAndSettle(.working)
        let plan = engine.shutdown()
        XCTAssertEqual(plan.desired, .baseline)
        XCTAssertTrue(engine.request(.notification, now: now).isEmpty,
                      "disabled engine must ignore requests")
    }

    // MARK: - In-flight coalescing

    func testRequestDuringWriteIsParkedThenReplayed() {
        let entry = engine.request(.notification, now: now) // in flight, not completed
        XCTAssertEqual(entry.count, 1)
        // A debounced request during the write parks after its window.
        _ = engine.request(.working, now: now)
        now += VibeKeyLedRenderEngine.debounceInterval
        let parked = engine.tick(now: now)
        XCTAssertTrue(parked.isEmpty)
        XCTAssertEqual(engine.pendingState, .working)
        engine.confirmDeviceState(entry[0].desired)
        let replay = engine.writeCompleted(success: true, now: now)
        XCTAssertEqual(engine.currentState, .working)
        XCTAssertEqual(replay.count, 1)
    }
}