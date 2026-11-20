import AppKit
import VibeKeyLiteCore

/// "Agent 灯效接入" window: a list of agent targets with detection status
/// and one-click install/uninstall. Hard gate: absent software is never
/// configured — the user is told to install it first (user requirement
/// 2026-11-20). QwenWork uses the enterprise-console HTTP flow.
final class AgentHooksWindowController: NSWindowController {
    private let tableView = NSTableView()
    private var detections: [VibeKeyHookInstaller.Detection] = []
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var qwenWorkListenerActive = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent 灯效接入"
        self.init(window: window)
        buildUI()
        refresh()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            "选择要接入灯效的 Agent。安装前会检测软件是否已安装；安装只新增带 vibekey-lite 标记的 hooks，卸载只移除这些条目，你已有的配置原样保留。")
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Agent"
        nameColumn.width = 170
        let statusColumn = NSTableColumn(identifier: .init("status"))
        statusColumn.title = "检测 / 接入"
        statusColumn.width = 170
        let actionColumn = NSTableColumn(identifier: .init("action"))
        actionColumn.title = "操作"
        actionColumn.width = 150
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(statusColumn)
        tableView.addTableColumn(actionColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3

        let refreshButton = NSButton(title: "重新检测", target: self, action: #selector(refresh))
        refreshButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [refreshButton, NSView(), closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [intro, scroll, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func closeWindow() {
        window?.close()
    }

    @objc private func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        detections = VibeKeyAgentTarget.allCases.map { target in
            var detection = VibeKeyHookInstaller.detect(
                target: target, homeDirectory: home, pathDirectories: pathDirectories
            )
            if target == .qwenwork {
                // QwenWork is a desktop app; detect the bundle.
                detection.detected = FileManager.default.fileExists(
                    atPath: "/Applications/QwenWork.app"
                ) || FileManager.default.fileExists(
                    atPath: NSHomeDirectory() + "/Applications/QwenWork.app"
                )
                detection.installed = qwenWorkListenerActive
            }
            return detection
        }
        tableView.reloadData()
    }

    private func ctlPath() -> String {
        let bundlePath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/vibekeyctl").path
        if FileManager.default.isExecutableFile(atPath: bundlePath) {
            return "\"\(bundlePath)\""
        }
        return "\"\(Bundle.main.bundleURL.path)/Contents/MacOS/vibekeyctl\""
    }

    private func performInstall(_ target: VibeKeyAgentTarget) {
        guard let detection = detections.first(where: { $0.target == target }) else { return }
        guard detection.detected else {
            let alert = NSAlert()
            alert.messageText = "未检测到 \(target.displayName)"
            alert.informativeText = "请先安装该软件，再回来接入灯效。"
            alert.addButton(withTitle: "打开下载页")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: target.downloadURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if target == .qwenwork {
            showQwenWorkGuide()
            return
        }
        if target == .dsh {
            performDshInstall(uninstall: false)
            return
        }
        guard target.usesClaudeJSONContract, let relative = target.settingsRelativePath else {
            statusLabel.stringValue = "\(target.displayName) 的专用安装器将在后续版本提供（S5）。"
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(relative)
        let existing = try? Data(contentsOf: settingsURL)
        do {
            let merged = try VibeKeyHookInstaller.mergedSettings(
                existing: existing, target: target, ctlPath: ctlPath()
            )
            try writeWithBackup(existing: existing, new: merged, at: settingsURL)
            let written = try Data(contentsOf: settingsURL)
            let root = try JSONSerialization.jsonObject(with: written) as? [String: Any] ?? [:]
            guard VibeKeyHookInstaller.containsMarker(in: root) else {
                statusLabel.stringValue = "读回校验失败：标记条目缺失。"
                return
            }
            if target == .codex {
                let configURL = home.appendingPathComponent(".codex/config.toml")
                let configExisting = try? String(contentsOf: configURL, encoding: .utf8)
                if let updated = VibeKeyHookInstaller.codexConfigEnablingHooks(existing: configExisting) {
                    try writeWithBackup(
                        existing: configExisting.map { Data($0.utf8) },
                        new: Data(updated.utf8), at: configURL
                    )
                }
                statusLabel.stringValue = "已接入 Codex。请在 Codex 内运行 /hooks 批准各条目后生效。"
            } else {
                statusLabel.stringValue = "已接入 \(target.displayName)。重启该 Agent 的会话后生效。"
            }
        } catch {
            statusLabel.stringValue = "安装失败：\(error.localizedDescription)"
        }
        refresh()
    }

    private func performUninstall(_ target: VibeKeyAgentTarget) {
        if target == .qwenwork {
            qwenWorkListenerActive = false
            statusLabel.stringValue = "已停止本机监听。请到企业管理后台清空对应 Hooks 规则。"
            refresh()
            return
        }
        if target == .dsh {
            performDshInstall(uninstall: true)
            return
        }
        guard let relative = target.settingsRelativePath else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative)
        guard let existing = try? Data(contentsOf: settingsURL) else {
            statusLabel.stringValue = "没有配置文件，无需卸载。"
            return
        }
        do {
            guard let unmerged = try VibeKeyHookInstaller.unmergedSettings(existing: existing) else {
                statusLabel.stringValue = "未找到 vibekey-lite 条目，无需卸载。"
                return
            }
            try writeWithBackup(existing: existing, new: unmerged, at: settingsURL)
            statusLabel.stringValue = "已卸载 \(target.displayName) 的灯效 hooks（其余配置保留）。"
        } catch {
            statusLabel.stringValue = "卸载失败：\(error.localizedDescription)"
        }
        refresh()
    }

    private func performDshInstall(uninstall: Bool) {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(VibeKeyAgentTarget.dsh.settingsRelativePath!)
        let existing = try? String(contentsOf: settingsURL, encoding: .utf8)
        do {
            if uninstall {
                guard let existing,
                      let unmerged = VibeKeyHookInstaller.unmergedDshPatch(existing: existing) else {
                    statusLabel.stringValue = "未找到 vibekey-lite 条目，无需卸载。"
                    return
                }
                try writeWithBackup(existing: Data(existing.utf8), new: Data(unmerged.utf8), at: settingsURL)
                statusLabel.stringValue = "已卸载 DSH 灯效 hooks。"
            } else {
                let merged = VibeKeyHookInstaller.mergedDshPatch(existing: existing, ctlPath: ctlPath())
                try writeWithBackup(existing: existing.map { Data($0.utf8) }, new: Data(merged.utf8), at: settingsURL)
                let written = try String(contentsOf: settingsURL, encoding: .utf8)
                guard written.contains("- id: \(VibeKeyHookInstaller.dshMarkerID)") else {
                    statusLabel.stringValue = "读回校验失败：DSH 标记条目缺失。"
                    return
                }
                statusLabel.stringValue = "已接入 DeepSeek Harness。重启 dsh 后生效。"
            }
        } catch {
            statusLabel.stringValue = "DSH 写入失败：\(error.localizedDescription)"
        }
        refresh()
    }

    private func writeWithBackup(existing: Data?, new: Data, at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            let backup = url.appendingPathExtension("bak-vibekey-\(Int(Date().timeIntervalSince1970))")
            try existing.write(to: backup)
        }
        try new.write(to: url, options: .atomic)
    }

    private func showQwenWorkGuide() {
        // Generate the per-event hook JSON for the enterprise console.
        var snippets: [String] = []
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "PreCompact"] {
            snippets.append("""
            // \(event)
            [{"hooks":[{"type":"http","url":"http://127.0.0.1:27950/qwenwork","timeout":3}]}]
            """)
        }
        let alert = NSAlert()
        alert.messageText = "千问办公接入（企业旗舰版）"
        alert.informativeText = """
        千问办公的 hooks 只能在企业管理后台配置（组织与安全 → 安全管控 → Hooks 规则），且仅支持 HTTP 类型。

        点「复制配置」后，到后台为下列事件分别粘贴：SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、Stop、Notification、PreCompact。

        注意：本机监听服务将在后续版本随 App 常驻启动；当前版本请先完成后台配置。
        """
        alert.addButton(withTitle: "复制配置")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippets.joined(separator: "\n\n"), forType: .string)
            statusLabel.stringValue = "已复制千问办公 Hooks 配置，请到企业管理后台粘贴。"
        }
    }
}

extension AgentHooksWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        detections.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let detection = detections[row]
        switch tableColumn?.identifier.rawValue {
        case "name":
            let label = NSTextField(labelWithString: detection.target.displayName)
            label.font = .systemFont(ofSize: 12)
            return label
        case "status":
            let detected = detection.detected ? "已安装" : "未检测到"
            let installed = detection.installed ? " · 已接入 ✓" : ""
            let label = NSTextField(labelWithString: detected + installed)
            label.font = .systemFont(ofSize: 11)
            label.textColor = detection.detected ? .secondaryLabelColor : .systemOrange
            return label
        case "action":
            let button: NSButton
            if detection.installed {
                button = NSButton(title: "卸载", target: self, action: #selector(uninstallClicked(_:)))
            } else {
                button = NSButton(title: "安装", target: self, action: #selector(installClicked(_:)))
            }
            button.bezelStyle = .rounded
            button.tag = row
            button.font = .systemFont(ofSize: 11)
            return button
        default:
            return nil
        }
    }

    @objc private func installClicked(_ sender: NSButton) {
        guard detections.indices.contains(sender.tag) else { return }
        performInstall(detections[sender.tag].target)
    }

    @objc private func uninstallClicked(_ sender: NSButton) {
        guard detections.indices.contains(sender.tag) else { return }
        performUninstall(detections[sender.tag].target)
    }
}