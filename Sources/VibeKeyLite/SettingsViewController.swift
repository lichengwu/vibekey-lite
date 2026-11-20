import AppKit
import VibeKeyLiteCore

final class SettingsViewController: NSViewController {
    var onProfileSelected: ((ProfileID) -> Void)?
    var onMappingChanged: ((ProfileID, InputControl, ControlBinding) -> Void)?
    var onRestartApplication: (() -> Void)?
    var onSyncHardware: (() -> Void)?
    var onToggleEnhancedMode: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowAgentHooks: (() -> Void)?

    private var configuration: AppConfiguration
    private var listenerActive = false
    private var accessibilityGranted = false
    private var deviceConnected = false
    private var powerStatus = VibeKeyPowerSnapshot()
    private var powerSaving = false
    private var hardwareSyncInProgress = false
    private var launchAtLoginEnabled = false
    private var notice: String?

    private let profileSelector = NSSegmentedControl(
        labels: ["AI", "系统"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var syncButton = NSButton(
        title: "离线备用",
        target: self,
        action: #selector(syncHardware(_:))
    )
    private lazy var restartButton = NSButton(
        title: "重启",
        target: self,
        action: #selector(restartApplication(_:))
    )
    private lazy var enhancedModeButton = NSButton(
        title: "只用原生",
        target: self,
        action: #selector(toggleEnhancedMode(_:))
    )
    private lazy var launchAtLoginButton = NSButton(
        checkboxWithTitle: "开机自启（重启电脑后自动运行）",
        target: self,
        action: #selector(toggleLaunchAtLogin(_:))
    )
    private var actionPopups: [InputControl: NSPopUpButton] = [:]
    private let recordShortcutToken = "__record_native_shortcut__"

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 390))

        let title = NSTextField(labelWithString: "VibeKey Lite")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let explanation = NSTextField(
            wrappingLabelWithString: "旋钮單按、双按可各自设置；按住 0.65 秒固定切换 AI／系统。"
        )
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)

        profileSelector.target = self
        profileSelector.action = #selector(profileChanged(_:))
        profileSelector.setAccessibilityLabel("目前设置组")

        let profileRow = NSStackView(views: [
            NSTextField(labelWithString: "目前设置组"),
            profileSelector
        ])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.distribution = .fill
        profileRow.spacing = 12

        let mappingGrid = makeMappingGrid()

        let syncExplanation = NSTextField(
            wrappingLabelWithString: "按「离线备用」才会把目前六个單按写进 AU05；App 结束后使用那一组。"
        )
        syncExplanation.textColor = .secondaryLabelColor
        syncExplanation.font = .systemFont(ofSize: 11)

        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.font = .systemFont(ofSize: 11)

        restartButton.bezelStyle = .rounded

        syncButton.bezelStyle = .rounded
        enhancedModeButton.bezelStyle = .rounded

        let quitButton = NSButton(
            title: "结束",
            target: self,
            action: #selector(quit(_:))
        )
        quitButton.bezelStyle = .rounded

        let agentHooksButton = NSButton(
            title: "Agent 灯效接入…",
            target: self,
            action: #selector(showAgentHooks(_:))
        )
        agentHooksButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [
            syncButton,
            restartButton,
            enhancedModeButton,
            agentHooksButton,
            NSView(),
            quitButton
        ])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [
            title,
            explanation,
            profileRow,
            mappingGrid,
            syncExplanation,
            statusLabel,
            buttons,
            launchAtLoginButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
            profileRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            mappingGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        reloadControls()
    }

    func update(
        configuration: AppConfiguration,
        listenerActive: Bool,
        accessibilityGranted: Bool,
        deviceConnected: Bool,
        powerStatus: VibeKeyPowerSnapshot,
        powerSaving: Bool,
        hardwareSyncInProgress: Bool,
        launchAtLoginEnabled: Bool,
        notice: String?
    ) {
        self.configuration = configuration
        self.listenerActive = listenerActive
        self.accessibilityGranted = accessibilityGranted
        self.deviceConnected = deviceConnected
        self.powerStatus = powerStatus
        self.powerSaving = powerSaving
        self.hardwareSyncInProgress = hardwareSyncInProgress
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.notice = notice

        if isViewLoaded {
            reloadControls()
        }
    }

    private func makeMappingGrid() -> NSGridView {
        let rows: [[NSView]] = InputControl.allCases.map { control in
            let label = NSTextField(
                labelWithString: control.displayName
            )
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.identifier = NSUserInterfaceItemIdentifier(control.rawValue)
            popup.target = self
            popup.action = #selector(mappingChanged(_:))

            popup.removeAllItems()
            for (categoryIndex, category) in KeyActionCategory.allCases.enumerated() {
                if categoryIndex > 0 {
                    popup.menu?.addItem(.separator())
                }

                let heading = NSMenuItem(title: category.rawValue, action: nil, keyEquivalent: "")
                heading.isEnabled = false
                popup.menu?.addItem(heading)

                for action in KeyAction.allCases where action.category == category {
                    if action == .switchProfile, control != .knobDoublePress {
                        continue
                    }
                    let supported = action == .switchProfile || action.isAppOnly
                        || PresetNativeShortcutResolver.resolve(action) != .unsupported
                    let title = supported
                        ? action.displayName
                        : "\(action.displayName)（AU05 离线不支持）"
                    popup.addItem(withTitle: title)
                    popup.lastItem?.representedObject = action.rawValue
                    popup.lastItem?.isEnabled = supported
                }
            }

            popup.menu?.addItem(.separator())
            let recordItem = NSMenuItem(
                title: "录制键盘按键…",
                action: nil,
                keyEquivalent: ""
            )
            recordItem.representedObject = recordShortcutToken
            popup.menu?.addItem(recordItem)

            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
            actionPopups[control] = popup
            return [label, popup]
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        return grid
    }

    private func reloadControls() {
        profileSelector.selectedSegment = configuration.activeProfile == .a ? 0 : 1
        profileSelector.isEnabled = !hardwareSyncInProgress
        syncButton.isEnabled = !hardwareSyncInProgress
        restartButton.isEnabled = !hardwareSyncInProgress
        enhancedModeButton.isEnabled = !hardwareSyncInProgress
        enhancedModeButton.title = listenerActive ? "只用原生" : "启用手势"
        syncButton.title = hardwareSyncInProgress ? "写入中…" : "离线备用"
        launchAtLoginButton.state = launchAtLoginEnabled ? .on : .off
        launchAtLoginButton.isEnabled = !hardwareSyncInProgress
        let profile = configuration.activeProfile

        for control in InputControl.allCases {
            let binding = configuration[profile][control]
            let popup = actionPopups[control]
            let matchingItem: NSMenuItem?
            switch binding {
            case let .preset(action):
                matchingItem = popup?.itemArray.first {
                    ($0.representedObject as? String) == action.rawValue
                }
                popup?.itemArray.first {
                    ($0.representedObject as? String) == recordShortcutToken
                }?.title = "录制键盘按键…"
            case let .shortcut(shortcut):
                matchingItem = popup?.itemArray.first {
                    ($0.representedObject as? String) == recordShortcutToken
                }
                matchingItem?.title = "自定义：\(shortcut.displayName)"
            }
            popup?.select(matchingItem)
            popup?.isEnabled = !hardwareSyncInProgress
        }

        let statusMessage: String
        if !accessibilityGranted {
            statusMessage = notice ?? "原生六键仍可用；允許辅助使用后才会启用多重手势。"
            statusLabel.textColor = .systemOrange
        } else if !listenerActive {
            statusMessage = notice ?? "原生按键仍可用；允許输入监控后才能长按切换。"
            statusLabel.textColor = .systemOrange
        } else if powerSaving {
            statusMessage = notice ?? "閒置省電中；控制器醒來后会自动恢复三种手势。"
            statusLabel.textColor = .secondaryLabelColor
        } else if let notice {
            statusMessage = notice
            if notice.hasPrefix("已写入") {
                statusLabel.textColor = .systemGreen
            } else if notice.hasPrefix("正在写入") {
                statusLabel.textColor = .secondaryLabelColor
            } else {
                statusLabel.textColor = .systemOrange
            }
        } else if deviceConnected {
            let offlineName = configuration.offlineProfile?.displayName ?? "尚未设置"
            statusMessage = "AU05 已连接；三种手势可用。离线备用：\(offlineName)。"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusMessage = "权限可用，正在等待 AU05。"
            statusLabel.textColor = .secondaryLabelColor
        }

        statusLabel.stringValue = "\(powerSummary)\n\(statusMessage)"
    }

    private var powerSummary: String {
        let batteryText: String
        if let battery = powerStatus.battery {
            if battery.isCharging {
                batteryText = "充電中 \(battery.percent)%"
            } else if battery.isFullyCharged {
                batteryText = "已充满 \(battery.percent)%"
            } else {
                batteryText = "電量 \(battery.percent)%"
            }
        } else {
            batteryText = "電量 —"
        }

        let standbyText = powerStatus.standbyTimeSeconds.map(Self.durationText) ?? "—"
        let sleepText = powerStatus.sleepTimeSeconds.map(Self.durationText) ?? "—"
        let stateText = powerSaving || powerStatus.isStandby == true ? "　省電中" : ""
        return "\(batteryText)　待机 \(standbyText)　关机 \(sleepText)\(stateText)"
    }

    private static func durationText(_ seconds: UInt32) -> String {
        if seconds > 0, seconds.isMultiple(of: 3_600) {
            return "\(seconds / 3_600) 小时"
        }
        if seconds > 0, seconds.isMultiple(of: 60) {
            return "\(seconds / 60) 分"
        }
        return "\(seconds) 秒"
    }

    @objc private func profileChanged(_ sender: NSSegmentedControl) {
        let profile: ProfileID = sender.selectedSegment == 0 ? .a : .b
        onProfileSelected?(profile)
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard let rawControl = sender.identifier?.rawValue,
              let control = InputControl(rawValue: rawControl),
              let rawAction = sender.selectedItem?.representedObject as? String else {
            return
        }
        let profile = configuration.activeProfile

        if rawAction == recordShortcutToken {
            guard let result = KeyboardShortcutRecorder.record() else {
                reloadControls()
                return
            }

            switch result {
            case let .success(shortcut):
                onMappingChanged?(
                    profile,
                    control,
                    .shortcut(shortcut)
                )
            case let .failure(error):
                let alert = NSAlert(error: error)
                alert.runModal()
                reloadControls()
            }
            return
        }

        guard let action = KeyAction(rawValue: rawAction) else {
            reloadControls()
            return
        }

        onMappingChanged?(
            profile,
            control,
            .preset(action)
        )
    }

    @objc private func restartApplication(_ sender: Any?) {
        onRestartApplication?()
    }

    @objc private func syncHardware(_ sender: Any?) {
        onSyncHardware?()
    }

    @objc private func toggleEnhancedMode(_ sender: Any?) {
        onToggleEnhancedMode?()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        onToggleLaunchAtLogin?()
    }

    @objc private func quit(_ sender: Any?) {
        onQuit?()
    }

    @objc private func showAgentHooks(_ sender: Any?) {
        onShowAgentHooks?()
    }
}
