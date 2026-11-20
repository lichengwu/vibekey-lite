import Foundation

/// M1 plan A: decides whether a frontmost-app activation should switch the
/// active profile. Pure logic so the rules are unit-testable without AppKit.
///
/// Rules (docs/dev-plan.md §2):
/// - A mapped bundleID switches to its profile, unless already active.
/// - An unmapped bundleID keeps the current profile (no fallback).
/// - A nil/empty bundleID (system UI, Spotlight transient focus) is ignored.
public enum VibeKeyAppProfileSwitcher {
    /// Returns the profile to switch to, or nil when nothing should change.
    public static func targetProfile(
        frontmostBundleID: String?,
        mapping: [String: ProfileID],
        currentProfile: ProfileID
    ) -> ProfileID? {
        guard let bundleID = frontmostBundleID, !bundleID.isEmpty else { return nil }
        guard let target = mapping[bundleID] else { return nil }
        guard target != currentProfile else { return nil }
        return target
    }

    /// Applies a profile switch with persist-or-rollback semantics, mirroring
    /// the AppDelegate path. Pure over its closures so the rollback contract
    /// is unit-testable without AppKit.
    /// - Returns: the profile now active (target on success, current on
    ///   persist failure or when no switch is needed).
    @discardableResult
    public static func applySwitch(
        target: ProfileID?,
        currentProfile: ProfileID,
        persist: (ProfileID) -> Bool
    ) -> ProfileID {
        guard let target, target != currentProfile else { return currentProfile }
        return persist(target) ? target : currentProfile
    }
}

/// Coalesces rapid frontmost-app activations: only the last bundleID within
/// the quiet window survives. Pure state machine; the app drives it with a
/// DispatchWorkItem timer.
public struct VibeKeyAppActivationDebouncer: Equatable, Sendable {
    public private(set) var pendingBundleID: String?
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Records a new activation, superseding any pending one.
    /// Returns the generation token the caller must match when the timer fires.
    public mutating func activate(_ bundleID: String?) -> UInt64 {
        pendingBundleID = bundleID
        generation &+= 1
        return generation
    }

    /// Timer callback: yields the bundleID only if the token is still current.
    public mutating func fire(generation token: UInt64) -> String? {
        guard token == generation else { return nil }
        let bundleID = pendingBundleID
        pendingBundleID = nil
        return bundleID
    }
}