import Foundation

/// Agent targets for one-click hook installation.
/// Claude Code / Qwen Code / Qoder / CodeBuddy share the Claude hooks JSON
/// contract; Codex uses config.toml; DSH uses cordis.patch.yml; QwenWork is
/// enterprise-console HTTP-only (handled separately by the app).
public enum VibeKeyAgentTarget: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude-code"
    case qwenCode = "qwen-code"
    case qoder
    case codebuddy
    case codex
    case dsh
    case qwenwork

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .qwenCode: return "Qwen Code（千问 CLI）"
        case .qoder: return "Qoder"
        case .codebuddy: return "CodeBuddy"
        case .codex: return "Codex"
        case .dsh: return "DeepSeek Harness"
        case .qwenwork: return "千问办公 QwenWork"
        }
    }

    /// User-level settings file the installer merges into (nil = special flow).
    public var settingsRelativePath: String? {
        switch self {
        case .claudeCode: return ".claude/settings.json"
        case .qwenCode: return ".qwen/settings.json"
        case .qoder: return ".qoder/settings.json"
        case .codebuddy: return ".codebuddy/settings.json"
        case .codex: return ".codex/config.toml"
        case .dsh: return ".dsh/profiles/web/cordis.patch.yml"
        case .qwenwork: return nil
        }
    }

    /// Detection candidates relative to home: any existing path means the
    /// software is present. Hard gate: never write config for absent agents.
    public var detectionRelativePaths: [String] {
        switch self {
        case .claudeCode: return [".claude"]
        case .qwenCode: return [".qwen"]
        case .qoder: return [".qoder"]
        case .codebuddy: return [".codebuddy"]
        case .codex: return [".codex"]
        case .dsh: return [".dsh"]
        case .qwenwork: return []
        }
    }

    /// PATH executables that also count as detected.
    public var detectionExecutables: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .qwenCode: return ["qwen"]
        case .qoder: return ["qoder"]
        case .codebuddy: return ["codebuddy"]
        case .codex: return ["codex"]
        case .dsh: return ["dsh"]
        case .qwenwork: return []
        }
    }

    public var downloadURL: String {
        switch self {
        case .claudeCode: return "https://claude.com/claude-code"
        case .qwenCode: return "https://qwenlm.github.io/qwen-code-docs/"
        case .qoder: return "https://qoder.com"
        case .codebuddy: return "https://www.codebuddy.ai"
        case .codex: return "https://github.com/openai/codex"
        case .dsh: return "https://github.com/deepseek-ai/dsh"
        case .qwenwork: return "https://www.aliyun.com/product/qwenwork"
        }
    }

    /// Events the installer wires for the Claude-compatible dialect.
    public static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Stop", "StopFailure", "Notification",
        "PermissionRequest", "PreCompact", "SessionEnd",
    ]

    public var hookDialect: String {
        self == .dsh ? "dsh" : "claude"
    }
}

public enum VibeKeyHookInstallerError: Error, Equatable, LocalizedError {
    case agentNotDetected(String)
    case invalidExistingJSON
    case unsupportedTarget(String)

    public var errorDescription: String? {
        switch self {
        case let .agentNotDetected(name):
            "未检测到 \(name)。请先安装该软件，再回来接入灯效。"
        case .invalidExistingJSON:
            "现有配置文件不是合法 JSON；已保留原文件，未做任何修改。"
        case let .unsupportedTarget(name):
            "\(name) 使用特殊接入流程，不走本地配置安装。"
        }
    }
}

/// Pure merge/unmerge logic for Claude-compatible settings.json files.
/// Additive only: existing hooks are preserved; our entries carry
/// `name: "vibekey-lite"` so uninstall removes exactly them.
public enum VibeKeyHookInstaller {
    public static let markerName = "vibekey-lite"

    /// Detection result for the UI list.
    public struct Detection: Equatable, Sendable {
        public var target: VibeKeyAgentTarget
        public var detected: Bool
        public var installed: Bool

        public init(target: VibeKeyAgentTarget, detected: Bool, installed: Bool) {
            self.target = target
            self.detected = detected
            self.installed = installed
        }
    }

    public static func detect(
        target: VibeKeyAgentTarget,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        pathDirectories: [String] = []
    ) -> Detection {
        var detected = target.detectionRelativePaths.contains { relative in
            fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(relative).path)
        }
        if !detected {
            detected = target.detectionExecutables.contains { executable in
                pathDirectories.contains { directory in
                    fileManager.isExecutableFile(
                        atPath: URL(fileURLWithPath: directory)
                            .appendingPathComponent(executable).path
                    )
                }
            }
        }
        var installed = false
        if let relative = target.settingsRelativePath, target.hookDialect == "claude" {
            let settingsURL = homeDirectory.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: settingsURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                installed = containsMarker(in: json)
            }
        }
        return Detection(target: target, detected: detected, installed: installed)
    }

    /// Builds the hook entry for one event.
    public static func hookEntry(
        target: VibeKeyAgentTarget,
        event: String,
        ctlPath: String
    ) -> [String: Any] {
        [
            "type": "command",
            "name": markerName,
            "command": "\(ctlPath) hook --agent \(target.rawValue) --event \(event)",
            "timeout": 5,
        ]
    }

    /// Merges our hooks into existing settings JSON data.
    /// - Preserves every existing entry; removes stale marker entries first
    ///   (idempotent reinstall).
    /// - Returns the new JSON data (pretty-printed, sorted keys).
    public static func mergedSettings(
        existing: Data?,
        target: VibeKeyAgentTarget,
        ctlPath: String
    ) throws -> Data {
        guard target.hookDialect == "claude", target.settingsRelativePath != nil else {
            throw VibeKeyHookInstallerError.unsupportedTarget(target.displayName)
        }
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            let parsed = try? JSONSerialization.jsonObject(with: existing)
            guard let parsed = parsed as? [String: Any] else {
                throw VibeKeyHookInstallerError.invalidExistingJSON
            }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in VibeKeyAgentTarget.claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Strip our old groups/entries, keep everything else.
            groups = groups.compactMap { group in
                var group = group
                if let entries = group["hooks"] as? [[String: Any]] {
                    let kept = entries.filter { ($0["name"] as? String) != markerName }
                    if kept.isEmpty { return nil }
                    group["hooks"] = kept
                }
                return group
            }
            groups.append([
                "matcher": "*",
                "hooks": [hookEntry(target: target, event: event, ctlPath: ctlPath)],
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Removes only marker entries. Returns nil when nothing changed.
    public static func unmergedSettings(existing: Data) throws -> Data? {
        let parsed = try? JSONSerialization.jsonObject(with: existing)
        guard var root = parsed as? [String: Any] else {
            throw VibeKeyHookInstallerError.invalidExistingJSON
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return nil }
        var changed = false
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var group = group
                if let entries = group["hooks"] as? [[String: Any]] {
                    let kept = entries.filter { ($0["name"] as? String) != markerName }
                    if kept.count != entries.count { changed = true }
                    if kept.isEmpty { return nil }
                    group["hooks"] = kept
                }
                return group
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        guard changed else { return nil }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
    }

    public static func containsMarker(in root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                if entries.contains(where: { ($0["name"] as? String) == markerName }) {
                    return true
                }
            }
        }
        return false
    }
}