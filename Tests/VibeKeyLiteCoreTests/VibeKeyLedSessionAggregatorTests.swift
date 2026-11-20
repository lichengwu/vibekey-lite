import XCTest
@testable import VibeKeyLiteCore

final class VibeKeyLedSessionAggregatorTests: XCTestCase {
    func testHighestPriorityWins() {
        var aggregator = VibeKeyLedSessionAggregator()
        _ = aggregator.record(session: "a", state: .working, now: 100)
        XCTAssertEqual(aggregator.record(session: "b", state: .thinking, now: 101), .thinking)
        XCTAssertEqual(aggregator.record(session: "c", state: .notification, now: 102), .notification)
        // Working session updates must not dethrone notification.
        XCTAssertEqual(aggregator.record(session: "a", state: .working, now: 103), .notification)
    }

    func testStaleSessionsAreDropped() {
        var aggregator = VibeKeyLedSessionAggregator(staleInterval: 120)
        _ = aggregator.record(session: "a", state: .notification, now: 100)
        _ = aggregator.record(session: "b", state: .working, now: 200)
        // At 221 the notification session is stale (>120s), working wins.
        XCTAssertEqual(aggregator.prune(now: 221), .working)
        XCTAssertEqual(aggregator.activeSessionCount, 1)
    }

    func testEmptyResolvesToIdle() {
        var aggregator = VibeKeyLedSessionAggregator()
        XCTAssertEqual(aggregator.resolvedState(now: 0), .idle)
        _ = aggregator.record(session: "a", state: .working, now: 0)
        XCTAssertEqual(aggregator.prune(now: 1000), .idle)
    }

    func testErrorBeatsWorkingButLosesToNotification() {
        var aggregator = VibeKeyLedSessionAggregator()
        _ = aggregator.record(session: "a", state: .error, now: 0)
        XCTAssertEqual(aggregator.record(session: "b", state: .working, now: 1), .error)
        XCTAssertEqual(aggregator.record(session: "c", state: .notification, now: 2), .notification)
    }

    func testStaleBoundaryIsExclusive() {
        var aggregator = VibeKeyLedSessionAggregator(staleInterval: 120)
        _ = aggregator.record(session: "a", state: .working, now: 0)
        // Exactly at the interval the session is stale (strict <).
        XCTAssertEqual(aggregator.resolvedState(now: 120), .idle)
        XCTAssertEqual(aggregator.resolvedState(now: 119.9), .working)
    }

    func testSameSessionUpdateReplacesState() {
        var aggregator = VibeKeyLedSessionAggregator()
        _ = aggregator.record(session: "a", state: .notification, now: 0)
        XCTAssertEqual(aggregator.record(session: "a", state: .idle, now: 1), .idle)
        XCTAssertEqual(aggregator.activeSessionCount, 1)
    }

    func testSweepingBeatsThinkingAndWorking() {
        var aggregator = VibeKeyLedSessionAggregator()
        _ = aggregator.record(session: "a", state: .thinking, now: 0)
        _ = aggregator.record(session: "b", state: .working, now: 0)
        XCTAssertEqual(aggregator.record(session: "c", state: .sweeping, now: 1), .sweeping)
    }

    func testAttentionBeatsIdleButLosesToWorking() {
        var aggregator = VibeKeyLedSessionAggregator()
        _ = aggregator.record(session: "a", state: .attention, now: 0)
        XCTAssertEqual(aggregator.record(session: "b", state: .idle, now: 1), .attention)
        XCTAssertEqual(aggregator.record(session: "c", state: .working, now: 2), .working)
    }

    func testPruneRemovesOnlyStaleAndKeepsFreshWinner() {
        var aggregator = VibeKeyLedSessionAggregator(staleInterval: 120)
        _ = aggregator.record(session: "old", state: .notification, now: 0)
        _ = aggregator.record(session: "fresh", state: .thinking, now: 100)
        XCTAssertEqual(aggregator.prune(now: 150), .thinking)
        XCTAssertEqual(aggregator.activeSessionCount, 1)
    }

    func testResolvedStateDoesNotMutateSessions() {
        var aggregator = VibeKeyLedSessionAggregator(staleInterval: 120)
        _ = aggregator.record(session: "a", state: .working, now: 0)
        _ = aggregator.resolvedState(now: 500) // stale but not pruned
        XCTAssertEqual(aggregator.activeSessionCount, 1,
                       "resolvedState must be a read-only view")
        XCTAssertEqual(aggregator.prune(now: 500), .idle)
    }
}

final class VibeKeyCodexAndDshInstallerTests: XCTestCase {
    func testCodexFeaturesAddedWhenAbsent() {
        let updated = VibeKeyHookInstaller.codexConfigEnablingHooks(existing: "model = \"gpt-5\"\n")
        XCTAssertNotNil(updated)
        XCTAssertTrue(updated!.contains("[features]"))
        XCTAssertTrue(updated!.contains("hooks = true"))
        XCTAssertTrue(updated!.contains("model = \"gpt-5\""))
    }

    func testCodexFeaturesIdempotent() {
        let existing = "[features]\nhooks = true\n"
        XCTAssertNil(VibeKeyHookInstaller.codexConfigEnablingHooks(existing: existing))
    }

    func testCodexFeaturesFalseFlipped() {
        let existing = "[features]\nhooks = false\n"
        let updated = VibeKeyHookInstaller.codexConfigEnablingHooks(existing: existing)
        XCTAssertEqual(updated, "[features]\nhooks = true\n")
    }

    func testCodexFeaturesInsertedIntoExistingSection() {
        let existing = "[features]\nother = 1\n\n[other]\nx = 2\n"
        let updated = VibeKeyHookInstaller.codexConfigEnablingHooks(existing: existing)!
        XCTAssertTrue(updated.contains("[features]\nhooks = true\nother = 1"))
        XCTAssertTrue(updated.contains("[other]"))
    }

    func testDshMergeIntoEmpty() {
        let merged = VibeKeyHookInstaller.mergedDshPatch(existing: nil, ctlPath: "/bin/ctl")
        XCTAssertTrue(merged.contains("- id: vibekey-lite-led"))
        XCTAssertTrue(merged.contains("approval/asked"))
        XCTAssertTrue(merged.contains("--dialect dsh"))
    }

    func testDshMergePreservesOtherItems() {
        let existing = "- id: other-plugin\n  config:\n    foo: bar\n"
        let merged = VibeKeyHookInstaller.mergedDshPatch(existing: existing, ctlPath: "/bin/ctl")
        XCTAssertTrue(merged.contains("- id: other-plugin"))
        XCTAssertTrue(merged.contains("foo: bar"))
        XCTAssertTrue(merged.contains("- id: vibekey-lite-led"))
    }

    func testDshReinstallReplacesMarkedBlockOnly() {
        let first = VibeKeyHookInstaller.mergedDshPatch(
            existing: "- id: other-plugin\n  config:\n    foo: bar\n", ctlPath: "/bin/ctl"
        )
        let second = VibeKeyHookInstaller.mergedDshPatch(existing: first, ctlPath: "/bin/ctl2")
        XCTAssertEqual(
            second.components(separatedBy: "- id: vibekey-lite-led").count - 1, 1,
            "marked block must appear exactly once"
        )
        XCTAssertTrue(second.contains("/bin/ctl2"))
        XCTAssertTrue(second.contains("- id: other-plugin"))
    }

    func testDshUninstallRemovesOnlyMarkedBlock() {
        let merged = VibeKeyHookInstaller.mergedDshPatch(
            existing: "- id: other-plugin\n  config:\n    foo: bar\n", ctlPath: "/bin/ctl"
        )
        let unmerged = VibeKeyHookInstaller.unmergedDshPatch(existing: merged)
        XCTAssertNotNil(unmerged)
        XCTAssertFalse(unmerged!.contains("vibekey-lite-led"))
        XCTAssertTrue(unmerged!.contains("- id: other-plugin"))
        XCTAssertTrue(unmerged!.contains("foo: bar"))
    }

    func testDshUninstallWithoutMarkerReturnsNil() {
        XCTAssertNil(VibeKeyHookInstaller.unmergedDshPatch(existing: "- id: other\n"))
    }

    func testCodexUsesClaudeJSONContract() throws {
        XCTAssertTrue(VibeKeyAgentTarget.codex.usesClaudeJSONContract)
        XCTAssertEqual(VibeKeyAgentTarget.codex.settingsRelativePath, ".codex/hooks.json")
        let data = try VibeKeyHookInstaller.mergedSettings(
            existing: nil, target: .codex, ctlPath: "/bin/ctl"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(VibeKeyHookInstaller.containsMarker(in: root))
    }
}