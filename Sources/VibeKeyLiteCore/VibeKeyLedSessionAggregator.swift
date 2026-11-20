import Foundation

/// Multi-session arbitration (docs/m2-led-design.md §3).
/// Pure logic: the app feeds events with timestamps; the aggregator decides
/// which single state the renderer should show.
///
/// Priority: notification > error > sweeping > thinking > working >
/// attention > idle/sleeping. Sessions silent for `staleInterval` are
/// dropped (mirrors the official stale-session cleanup).
public struct VibeKeyLedSessionAggregator: Equatable, Sendable {
    public struct Session: Equatable, Sendable {
        public var state: VibeKeyAgentState
        public var lastSeen: TimeInterval

        public init(state: VibeKeyAgentState, lastSeen: TimeInterval) {
            self.state = state
            self.lastSeen = lastSeen
        }
    }

    public private(set) var sessions: [String: Session] = [:]
    public let staleInterval: TimeInterval

    public init(staleInterval: TimeInterval = 120) {
        self.staleInterval = staleInterval
    }

    /// Records an event and returns the state that should now be rendered.
    public mutating func record(
        session: String,
        state: VibeKeyAgentState,
        now: TimeInterval
    ) -> VibeKeyAgentState {
        sessions[session] = Session(state: state, lastSeen: now)
        return resolvedState(now: now)
    }

    /// Drops stale sessions and returns the resolved state.
    public mutating func prune(now: TimeInterval) -> VibeKeyAgentState {
        sessions = sessions.filter { now - $0.value.lastSeen < staleInterval }
        return resolvedState(now: now)
    }

    public func resolvedState(now: TimeInterval) -> VibeKeyAgentState {
        let active = sessions.values.filter { now - $0.lastSeen < staleInterval }
        guard let winner = active.max(by: { $0.state.priority < $1.state.priority }) else {
            return .idle
        }
        return winner.state
    }

    public var activeSessionCount: Int { sessions.count }
}