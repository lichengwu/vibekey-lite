import AppKit
import OSLog
import ServiceManagement
import VibeKeyLiteCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hardwareConfigurator: any HardwareConfigurator
    private var configuration = AppConfiguration.default
    private var configStore: ConfigStore?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsViewController: SettingsViewController?
    private var hardwareListener: IOKitHardwareListener?
    private var ledRenderer: LedRenderer?
    private var ctlServer: CtlSocketServer?
    private var agentHooksWindowController: AgentHooksWindowController?
    private var qwenWorkListener: QwenWorkHookListener?
    private var ledSessionAggregator = VibeKeyLedSessionAggregator()
    private var ledStaleTimer: Timer?
    private var appProfileDebounceWorkItem: DispatchWorkItem?
    private var appActivationDebouncer = VibeKeyAppActivationDebouncer()
    private var workspaceObservers: [NSObjectProtocol] = []
    private let actionPerformer = ActionPerformer()
    private var knobPressStateMachine = KnobPressStateMachine()
    private var knobLongPressTimer: Timer?
    private var knobSinglePressTimer: Timer?
    private var powerHandoffTimer: Timer?
    private var connectionRecoveryTimer: Timer?
    private var connectionRecoveryAttemptsRemaining = 0
    private var powerHandoffStateMachine = VibeKeyPowerHandoffStateMachine(idleInterval: 300)
    private let logger = Logger(
        subsystem: "io.github.arumwu.VibeKeyLite",
        category: "HID"
    )

    private var listenerActive = false
    private var accessibilityGranted = false
    private var deviceConnected = false
    private var devicePowerStatus = VibeKeyPowerSnapshot()
    private var powerSaving = false
    private var hardwareSyncInProgress = false
    private var vendorInterferedDuringHardwareSync = false
    private var needsHardwareSync = false
    private var configurationReady = false
    private var enhancedModeRequested = true
    private var offlineStateUnconfirmed = false
    private var notice: String?

    override init() {
        hardwareConfigurator = IOKitHardwareConfigurator()
        super.init()
    }

    init(hardwareConfigurator: any HardwareConfigurator) {
        self.hardwareConfigurator = hardwareConfigurator
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadConfiguration()
        DebugLog.log("launch: offlineProfile=\(configuration.offlineProfile?.rawValue ?? "nil") needsHardwareSync=\(needsHardwareSync) activeProfile=\(configuration.activeProfile.rawValue)")
        configureStatusItemAndPopover()
        configureHardwareListener()
        configureLedRendering()
        configureLifecycleObservers()
        // M1: align the profile with whatever app is already frontmost at launch.
        applyAppProfileSwitch(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        refreshUI()

        if needsHardwareSync {
            notice = "请按「离线备用」确認写回完整六键；确認前不会改动 AU05。"
            refreshUI()
        } else {
            startHardwareListener(promptForPermission: true)
            scheduleConnectionRecovery()
        }

        if ProcessInfo.processInfo.environment["VIBEKEY_SHOW_SETTINGS"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        powerHandoffTimer?.invalidate()
        powerHandoffTimer = nil
        connectionRecoveryTimer?.invalidate()
        connectionRecoveryTimer = nil
        resetKnobPressState()
        actionPerformer.releaseAll()
        ctlServer?.stop()
        ctlServer = nil
        qwenWorkListener?.stop()
        qwenWorkListener = nil
        ledStaleTimer?.invalidate()
        ledStaleTimer = nil
        ledRenderer?.shutdown()
        ledRenderer = nil
        if let error = hardwareListener?.stop() {
            logger.error("Offline shutdown failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hardwareSyncInProgress else { return .terminateNow }
        notice = "AU05 写入中；完成后再结束 App。"
        refreshUI()
        return .terminateCancel
    }

    // MARK: - LED rendering + ctl socket

    private func showAgentHooksWindow() {
        if agentHooksWindowController == nil {
            let controller = AgentHooksWindowController()
            controller.onStartQwenWorkListener = { [weak self] in
                self?.startQwenWorkListener()
            }
            controller.onStopQwenWorkListener = { [weak self] in
                self?.qwenWorkListener?.stop()
                self?.qwenWorkListener = nil
            }
            controller.isQwenWorkListenerRunning = { [weak self] in
                self?.qwenWorkListener?.isRunning ?? false
            }
            controller.qwenWorkSnippets = { [weak self] in
                guard let token = self?.qwenWorkListener?.token else { return [:] }
                let port = self?.qwenWorkListener?.port ?? VibeKeyQwenWorkHookHandler.defaultPort
                return VibeKeyQwenWorkHookHandler.consoleSnippets(port: port, token: token)
            }
            agentHooksWindowController = controller
        }
        agentHooksWindowController?.showWindow(nil)
        agentHooksWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Starts the loopback listener on demand (install flow only; never at
    /// launch). Returns the bearer token on success, nil on failure.
    private func startQwenWorkListener() -> String? {
        if let existing = qwenWorkListener, existing.isRunning {
            return existing.token
        }
        let listener = QwenWorkHookListener { [weak self] state in
            guard let self, let renderer = self.ledRenderer else { return }
            let resolved = self.ledSessionAggregator.record(
                session: "qwenwork", state: state, now: Date().timeIntervalSince1970
            )
            renderer.request(resolved)
        }
        do {
            try listener.start()
            qwenWorkListener = listener
            return listener.token
        } catch {
            logger.error("QwenWork listener start failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func configureLedRendering() {
        let renderer = LedRenderer(
            apply: { [weak self] desired, expected, completion in
                guard let listener = self?.hardwareListener, self?.listenerActive == true else {
                    completion(IOKitHardwareListenerError.onlinePrerequisiteLost)
                    return
                }
                listener.applyLedState(desired, expected: expected, completion: completion)
            },
            readState: { [weak self] completion in
                guard let listener = self?.hardwareListener, self?.listenerActive == true else {
                    completion(nil, IOKitHardwareListenerError.onlinePrerequisiteLost)
                    return
                }
                listener.readLedState(completion: completion)
            }
        )
        ledRenderer = renderer
        let staleTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let renderer = self.ledRenderer else { return }
            let resolved = self.ledSessionAggregator.prune(now: Date().timeIntervalSince1970)
            if resolved != renderer.state {
                renderer.request(resolved)
            }
        }
        RunLoop.main.add(staleTimer, forMode: .common)
        ledStaleTimer = staleTimer
        let server = CtlSocketServer { [weak self] request in
            self?.handleCtlRequest(request) ?? .init(ok: false, error: "App 未就绪")
        }
        server.start()
        ctlServer = server
    }

    private func handleCtlRequest(_ request: VibeKeyCtlProtocol.Request) -> VibeKeyCtlProtocol.Response {
        guard let renderer = ledRenderer else {
            return .init(ok: false, error: "灯效渲染器未就绪")
        }
        switch request.command {
        case "led":
            guard let raw = request.state, let state = VibeKeyAgentState(rawValue: raw) else {
                return .init(ok: false, error: "未知状态 \(request.state ?? "nil")")
            }
            renderer.request(state)
            return .init(ok: true, state: state.rawValue)
        case "hook":
            guard let event = request.event else {
                return .init(ok: false, error: "缺少 event")
            }
            let dialect = request.dialect ?? "claude"
            guard let state = VibeKeyAgentEventMapper.state(
                agentDialect: dialect, event: event, when: request.when
            ) else {
                return .init(ok: true, state: renderer.state.rawValue)
            }
            let session = request.session ?? "default"
            let resolved = ledSessionAggregator.record(
                session: session, state: state, now: Date().timeIntervalSince1970
            )
            renderer.request(resolved)
            return .init(ok: true, state: resolved.rawValue)
        case "restore":
            renderer.shutdown()
            return .init(ok: true, state: "off")
        case "status":
            return .init(ok: true, state: renderer.state.rawValue)
        default:
            return .init(ok: false, error: "未知命令 \(request.command)")
        }
    }

    private func loadConfiguration() {
        do {
            let url = try ConfigStore.defaultConfigURL()
            let store = ConfigStore(configURL: url)
            configuration = try store.loadOrCreate()
            let migratedKnob = configuration.restoreLegacyReservedKnobMappings()
            let needsInitialNativeBackup = configuration.offlineProfile == nil
            if migratedKnob || needsInitialNativeBackup {
                configuration.needsHardwareSync = true
                try store.save(configuration)
            }
            needsHardwareSync = configuration.needsHardwareSync
            configStore = store
            configurationReady = true
        } catch {
            configurationReady = false
            notice = "配置文件读取失败：\(error.localizedDescription)"
        }
    }

    private func configureStatusItemAndPopover() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        self.statusItem = statusItem

        let settings = SettingsViewController(configuration: configuration)
        settings.onProfileSelected = { [weak self] profile in
            guard let self else { return }
            guard !self.hardwareSyncInProgress else {
                self.refreshUI()
                return
            }
            guard profile != self.configuration.activeProfile else { return }
            let previousConfiguration = self.configuration
            self.cancelPendingInput()
            self.configuration.activeProfile = profile
            guard self.persistConfiguration() else {
                self.configuration = previousConfiguration
                self.refreshUI()
                return
            }
            self.notice = "已切换到「\(profile.displayName)」；离线备用未更动。"
            self.refreshUI()
        }
        settings.onMappingChanged = { [weak self] profile, control, binding in
            guard let self else { return }
            guard !self.hardwareSyncInProgress else {
                self.refreshUI()
                return
            }
            let previousConfiguration = self.configuration
            var profileConfiguration = self.configuration[profile]
            profileConfiguration[control] = binding
            self.configuration[profile] = profileConfiguration
            guard self.persistConfiguration() else {
                self.configuration = previousConfiguration
                self.refreshUI()
                return
            }
            if case .preset(let action) = binding, action.isAppOnly {
                self.notice = "App 专属键已保存；只在 App 开启时执行，离线六键会為它写入空槽。"
            } else {
                self.notice = control.isNativeHardwareControl
                    ? "设置已保存；按「設為离线备用」才会写入 AU05。"
                    : "双按设置已保存。"
            }
            self.refreshUI()
        }
        settings.onRestartApplication = { [weak self] in
            self?.restartApplication()
        }
        settings.onSyncHardware = { [weak self] in
            self?.syncHardwareFromUI()
        }
        settings.onToggleEnhancedMode = { [weak self] in
            self?.toggleEnhancedMode()
        }
        settings.onToggleLaunchAtLogin = { [weak self] in
            self?.toggleLaunchAtLogin()
        }
        settings.onQuit = {
            NSApplication.shared.terminate(nil)
        }
        settings.onShowAgentHooks = { [weak self] in
            self?.showAgentHooksWindow()
        }
        settingsViewController = settings

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 365)
        popover.contentViewController = settings
        self.popover = popover
    }

    private func configureHardwareListener() {
        let listener = IOKitHardwareListener(
            eventHandler: { [weak self] deviceEvent, timestamp in
                self?.handle(deviceEvent, at: timestamp)
            },
            powerResponseHandler: { [weak self] response in
                guard let self else { return }
                self.devicePowerStatus.apply(response)
                if case let .standbyTime(seconds) = response {
                    self.applyPowerHandoffDecisions(
                        self.powerHandoffStateMachine.updateIdleInterval(
                            TimeInterval(seconds),
                            at: HIDMonotonicClock.now
                        )
                    )
                }
                self.refreshUI()
            },
            noticeHandler: { [weak self] notice in
                guard let self else { return }
                if case let .standby(status) = notice {
                    self.devicePowerStatus.isStandby = status != 0
                }
                self.applyPowerHandoffDecisions(
                    self.powerHandoffStateMachine.noticeReceived(notice)
                )
                self.refreshUI()
            },
            powerSavingWakeHandler: { [weak self] in
                guard let self else { return }
                self.applyPowerHandoffDecisions(
                    self.powerHandoffStateMachine.wakeInputReceived()
                )
            },
            connectionHandler: { [weak self] connected in
                guard let self else { return }
                self.deviceConnected = connected
                if !connected {
                    self.devicePowerStatus = VibeKeyPowerSnapshot()
                    self.powerSaving = false
                    self.cancelPowerHandoff(
                        reason: .onlinePrerequisiteLost
                    )
                } else {
                    self.connectionRecoveryTimer?.invalidate()
                    self.connectionRecoveryTimer = nil
                    self.connectionRecoveryAttemptsRemaining = 0
                    self.applyPowerHandoffDecisions(
                        self.powerHandoffStateMachine.onlineStarted(
                            at: HIDMonotonicClock.now
                        )
                    )
                }
                if connected,
                   self.notice?.hasPrefix("AU05 已移除") == true
                    || self.notice?.hasPrefix("AU05 重新启动") == true
                    || self.notice?.hasPrefix("等待 AU05") == true {
                    self.notice = nil
                }
                self.refreshUI()
            },
            failureHandler: { [weak self] error in
                guard let self else { return }
                let stopError = self.suspendEnhancedMode()
                self.notice = (stopError ?? error).localizedDescription
                self.refreshUI()
            },
            deviceRemovalHandler: { [weak self] in
                self?.handleDeviceRemoval()
            },
            shouldRemainOnline: { [weak self] in
                guard let self else { return false }
                return self.onlinePreflightIsValid
            }
        )
        hardwareListener = listener
    }

    private func configureLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopEnhancedMode(
                notice: "Mac 即将睡眠；AU05 已退回设备原生按键。"
            )
        })

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopEnhancedMode(
                notice: "Mac 即将关机；AU05 已退回设备原生按键。"
            )
        })

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeAfterUserActivityIfNeeded()
        })

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard Self.isVendorApplication(notification) else { return }
            if self?.hardwareSyncInProgress == true {
                self?.vendorInterferedDuringHardwareSync = true
            }
            self?.ledRenderer?.suspendForVendor()
            self?.stopEnhancedMode(
                notice: "Ulanzi Studio 已开启；AU05 已退回设备原生按键。"
            )
        })

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard Self.isVendorApplication(notification) else { return }
            self?.resumeEnhancedModeIfSafe()
            self?.ledRenderer?.resume()
        })

        // M1: auto-switch profile by frontmost app (config appProfileMapping).
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            self?.scheduleAppProfileSwitch(bundleID: app.bundleIdentifier)
        })
    }

    private static func isVendorApplication(_ notification: Notification) -> Bool {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        return application?.bundleIdentifier == "ulanzi.UlanziStudio"
    }

    private func stopEnhancedMode(
        notice: String,
        reason: VibeKeyPowerHandoffSuspensionReason = .onlinePrerequisiteLost
    ) {
        let offlineError = suspendEnhancedMode(reason: reason)
        self.notice = offlineError?.localizedDescription ?? notice
        refreshUI()
    }

    private func suspendEnhancedMode(
        reason: VibeKeyPowerHandoffSuspensionReason = .onlinePrerequisiteLost
    ) -> Error? {
        cancelPowerHandoff(reason: reason)
        cancelPendingInput()
        let hadAttachedDevice = hardwareListener?.hasAttachedDevice == true
        let offlineError = hardwareListener?.stop()
        if offlineError != nil {
            offlineStateUnconfirmed = true
        } else if hadAttachedDevice {
            offlineStateUnconfirmed = false
        }
        listenerActive = false
        deviceConnected = false
        devicePowerStatus = VibeKeyPowerSnapshot()
        powerSaving = false
        return offlineError
    }

    private func toggleEnhancedMode() {
        if listenerActive {
            enhancedModeRequested = false
            stopEnhancedMode(
                notice: "已切回 AU05 原生六键。",
                reason: .manualNative
            )
            return
        }

        enhancedModeRequested = true
        if needsHardwareSync {
            notice = "请先按「离线备用」确認完整六键；不会自动改写 AU05。"
            refreshUI()
        } else {
            startHardwareListener(promptForPermission: true)
        }
    }

    private func resumeEnhancedModeIfSafe() {
        guard !listenerActive,
              enhancedModeRequested,
              !hardwareSyncInProgress,
              !needsHardwareSync else { return }
        startHardwareListener(promptForPermission: false)
    }

    private func resumeAfterUserActivityIfNeeded() {
        // Opening the menu is not AU05 activity. While native power saving is
        // active, only a completed physical AU05 input should restore online
        // gestures; otherwise merely checking battery status wakes its lights.
        guard !powerSaving else { return }
        resumeEnhancedModeIfSafe()
    }

    private func applyPowerHandoffDecisions(
        _ decisions: [VibeKeyPowerHandoffDecision]
    ) {
        for decision in decisions {
            switch decision {
            case let .scheduleStandbyHandoff(deadline):
                powerHandoffTimer?.invalidate()
                let delay = max(0, deadline - HIDMonotonicClock.now)
                let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.powerHandoffTimer = nil
                    self.applyPowerHandoffDecisions(
                        self.powerHandoffStateMachine.standbyHandoffDeadlineReached(
                            at: HIDMonotonicClock.now
                        )
                    )
                }
                powerHandoffTimer = timer
                RunLoop.main.add(timer, forMode: .common)

            case .cancelStandbyHandoff:
                powerHandoffTimer?.invalidate()
                powerHandoffTimer = nil

            case .handoffForStandby:
                guard listenerActive,
                      deviceConnected,
                      !hardwareSyncInProgress,
                      !needsHardwareSync else {
                    cancelPowerHandoff(reason: .onlinePrerequisiteLost)
                    return
                }
                cancelPendingInput()
                if let error = hardwareListener?.enterPowerSavingMode() {
                    let stopError = suspendEnhancedMode()
                    notice = (stopError ?? error).localizedDescription
                } else {
                    powerSaving = true
                    notice = "閒置省電中；控制器醒來后会自动恢复三种手势。"
                }
                refreshUI()

            case .resumeOnline:
                guard powerSaving else { continue }
                if let error = hardwareListener?.resumeFromPowerSaving() {
                    let stopError = suspendEnhancedMode()
                    logger.error(
                        "Controller wake connection was stale: \(error.localizedDescription, privacy: .public)"
                    )
                    if let stopError {
                        logger.error(
                            "Stale connection cleanup reported: \(stopError.localizedDescription, privacy: .public)"
                        )
                    }
                    notice = "AU05 重新启动；正在自动重建连接。"
                    scheduleConnectionRecovery()
                } else {
                    powerSaving = false
                    devicePowerStatus.isStandby = false
                    if notice?.hasPrefix("閒置省電中") == true {
                        notice = nil
                    }
                    applyPowerHandoffDecisions(
                        powerHandoffStateMachine.onlineStarted(
                            at: HIDMonotonicClock.now
                        )
                    )
                }
                refreshUI()
            }
        }
    }

    private func cancelPowerHandoff(reason: VibeKeyPowerHandoffSuspensionReason) {
        powerHandoffTimer?.invalidate()
        powerHandoffTimer = nil
        _ = powerHandoffStateMachine.suspendAutomaticResume(reason: reason)
    }

    private func restartApplication() {
        guard !hardwareSyncInProgress else {
            notice = "AU05 写入中；完成后再重启 App。"
            refreshUI()
            return
        }

        if let error = suspendEnhancedMode() {
            notice = "尚未重启：\(error.localizedDescription)"
            refreshUI()
            return
        }
        guard !offlineStateUnconfirmed else {
            notice = "尚未确認 AU05 已回原生模式；请先完成一次「离线备用」，再重启。"
            refreshUI()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.notice = "重新启动失败：\(error.localizedDescription)"
                    self?.resumeEnhancedModeIfSafe()
                    self?.refreshUI()
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func startHardwareListener(promptForPermission: Bool) {
        cancelPendingInput()

        guard enhancedModeRequested else { return }

        guard configurationReady else {
            listenerActive = false
            deviceConnected = false
            notice = "配置文件无法使用；AU05 保持设备原生模式。"
            refreshUI()
            return
        }

        accessibilityGranted = AccessibilityAccess.isTrusted(
            promptForPermission: promptForPermission
        )
        DebugLog.log("startHardwareListener: accessibilityGranted=\(accessibilityGranted) vendorNotRunning=\(vendorApplicationIsNotRunning)")
        guard accessibilityGranted else {
            listenerActive = false
            deviceConnected = false
            notice = "原生六键仍可用；允許「辅助使用」后，双按与长按才会启用。"
            refreshUI()
            return
        }

        guard vendorApplicationIsNotRunning else {
            listenerActive = false
            deviceConnected = false
            notice = "Ulanzi Studio 正在运行，按键由它接管。点「离线备用」会自动退出它并写入。"
            refreshUI()
            return
        }

        do {
            try validateAllProfilesForOnlineMode()
        } catch {
            listenerActive = false
            deviceConnected = false
            notice = "原生六键仍可用；进階手势设置无效：\(error.localizedDescription)"
            refreshUI()
            return
        }

        do {
            try hardwareListener?.start(promptForPermission: promptForPermission)
            listenerActive = true
            DebugLog.log("startHardwareListener: listener started OK")
            if notice?.contains("权限") == true || notice?.hasPrefix("监听失败") == true {
                notice = nil
            }
        } catch {
            listenerActive = false
            deviceConnected = false
            notice = "监听失败：\(error.localizedDescription)"
        logger.error(
            "Listener startup failed: \(error.localizedDescription, privacy: .public)"
        )
        DebugLog.log("startHardwareListener FAILED: \(error.localizedDescription)")
        }

        refreshUI()
    }

    private func scheduleConnectionRecovery() {
        guard !deviceConnected,
              enhancedModeRequested,
              !needsHardwareSync else { return }
        connectionRecoveryAttemptsRemaining = 3
        scheduleNextConnectionRecovery()
    }

    private func scheduleNextConnectionRecovery() {
        connectionRecoveryTimer?.invalidate()
        guard connectionRecoveryAttemptsRemaining > 0,
              !deviceConnected else { return }

        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.connectionRecoveryTimer = nil
            guard !self.deviceConnected,
                  self.enhancedModeRequested,
                  !self.needsHardwareSync else { return }

            self.connectionRecoveryAttemptsRemaining -= 1
            self.logger.notice(
                "Rebuilding AU05 connection; attempts remaining=\(self.connectionRecoveryAttemptsRemaining, privacy: .public)"
            )
            if let error = self.suspendEnhancedMode() {
                // A fully powered-off controller can make the final offline
                // write fail. The manager was still closed, so continue with
                // a fresh HID session instead of requiring an app restart.
                self.logger.error(
                    "Connection reset cleanup reported: \(error.localizedDescription, privacy: .public)"
                )
            }
            self.startHardwareListener(promptForPermission: false)
            guard self.listenerActive, !self.deviceConnected else { return }
            if self.connectionRecoveryAttemptsRemaining > 0 {
                self.scheduleNextConnectionRecovery()
            } else {
                self.notice = "等待 AU05 重新开机；侦测到后会自动接回。"
                self.refreshUI()
            }
        }
        connectionRecoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetKnobPressState() {
        knobLongPressTimer?.invalidate()
        knobLongPressTimer = nil
        knobSinglePressTimer?.invalidate()
        knobSinglePressTimer = nil
        knobPressStateMachine.reset()
    }

    private func cancelPendingInput() {
        resetKnobPressState()
        actionPerformer.releaseAll()
    }

    private func handleDeviceRemoval() {
        cancelPowerHandoff(reason: .onlinePrerequisiteLost)
        cancelPendingInput()
        offlineStateUnconfirmed = false
        deviceConnected = false
        devicePowerStatus = VibeKeyPowerSnapshot()
        powerSaving = false
        notice = "AU05 已移除；未完成的旋钮按压已取消。"
        refreshUI()
    }

    private func handle(_ deviceEvent: DeviceEvent, at timestamp: TimeInterval) {
        guard listenerActive,
              deviceConnected,
              !hardwareSyncInProgress,
              !needsHardwareSync else { return }
        applyPowerHandoffDecisions(
            powerHandoffStateMachine.deviceInput(at: timestamp)
        )
        let eventTime = String(format: "%.6f", timestamp)
        DebugLog.log("HID event: \(deviceEvent)")
        logger.notice(
            "HID event: \(String(describing: deviceEvent), privacy: .public) time=\(eventTime, privacy: .public)"
        )
        switch deviceEvent {
        case let .key(control: .knobPress, phase: phase):
            handleKnobPress(phase, at: timestamp)
        case let .key(control: control, phase: phase):
            handleOrdinaryControl(control, phase: phase)
        }
    }

    private func handleOrdinaryControl(_ control: InputControl, phase: KeyPhase) {
        let binding = configuration[configuration.activeProfile][control]
        guard binding.holdsSyntheticKey else {
            guard phase == .down else { return }
            do {
                // AU05 controls are macro triggers. Send one complete tap on
                // down so a crash can never leave a synthetic modifier held.
                try actionPerformer.tap(binding, for: control)
            } catch {
                notice = "按键执行失败：\(error.localizedDescription)"
                refreshUI()
            }
            return
        }
        // Push-to-talk actions: hold the synthetic key between device down/up.
        do {
            if phase == .down {
                DebugLog.log("voice: press (FN down)")
                try actionPerformer.press(binding, for: control)
            } else {
                DebugLog.log("voice: release (FN up)")
                actionPerformer.release(for: control)
            }
        } catch {
            DebugLog.log("voice FAILED: \(error.localizedDescription)")
            notice = "按键执行失败：\(error.localizedDescription)"
            refreshUI()
        }
    }

    private func handleKnobPress(_ phase: KeyPhase, at timestamp: TimeInterval) {
        switch phase {
        case .down:
            applyKnobPressDecisions(knobPressStateMachine.pressDown(at: timestamp))
        case .up:
            knobLongPressTimer?.invalidate()
            knobLongPressTimer = nil
            applyKnobPressDecisions(knobPressStateMachine.pressUp(at: timestamp))
        }
    }

    private func applyKnobPressDecisions(_ decisions: [KnobPressDecision]) {
        for decision in decisions {
            applyKnobPressDecision(decision)
        }
    }

    private func applyKnobPressDecision(_ decision: KnobPressDecision) {
        logger.notice("Knob decision: \(String(describing: decision), privacy: .public)")
        switch decision {
        case let .scheduleLongPress(delay):
            knobLongPressTimer?.invalidate()
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.knobLongPressTimer = nil
                self.applyKnobPressDecisions(
                    self.knobPressStateMachine.longPressTimerFired()
                )
            }
            knobLongPressTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case let .scheduleSinglePress(delay):
            knobSinglePressTimer?.invalidate()
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.knobSinglePressTimer = nil
                if let decision = self.knobPressStateMachine.singlePressTimerFired() {
                    self.applyKnobPressDecision(decision)
                }
            }
            knobSinglePressTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case .cancelPendingSinglePress:
            knobSinglePressTimer?.invalidate()
            knobSinglePressTimer = nil
        case .performSinglePress:
            performGestureBinding(for: .knobPress)
        case .performDoublePress:
            performGestureBinding(for: .knobDoublePress)
        case .longPressRecognized:
            notice = "已辨识长按；放开旋钮后切换设置组。"
            refreshUI()
        case .switchProfile:
            switchProfile()
        }
    }

    private func performGestureBinding(for control: InputControl) {
        let binding = configuration[configuration.activeProfile][control]
        if binding == .preset(.switchProfile) {
            switchProfile()
            return
        }

        do {
            try actionPerformer.tap(binding, for: control)
        } catch {
            notice = "按键执行失败：\(error.localizedDescription)"
            refreshUI()
        }
    }

    private func switchProfile() {
        let previousConfiguration = configuration
        actionPerformer.releaseAll()
        configuration.activeProfile = configuration.activeProfile.toggled
        guard persistConfiguration() else {
            configuration = previousConfiguration
            refreshUI()
            return
        }
        logger.notice(
            "Profile switched to \(self.configuration.activeProfile.rawValue, privacy: .public)"
        )
        notice = "已切换到「\(configuration.activeProfile.displayName)」；离线备用未更动。"
        refreshUI()
    }

    // MARK: - M1 frontmost-app profile switching

    /// 200 ms debounce absorbs ⌘Tab / Mission Control activation storms.
    /// The Core debouncer guarantees only the latest activation survives.
    private func scheduleAppProfileSwitch(bundleID: String?) {
        appProfileDebounceWorkItem?.cancel()
        let token = appActivationDebouncer.activate(bundleID)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let settled = self.appActivationDebouncer.fire(generation: token)
            else { return }
            self.applyAppProfileSwitch(bundleID: settled)
        }
        appProfileDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func applyAppProfileSwitch(bundleID: String?) {
        guard configurationReady, !hardwareSyncInProgress else { return }
        guard let target = VibeKeyAppProfileSwitcher.targetProfile(
            frontmostBundleID: bundleID,
            mapping: configuration.appProfileMapping,
            currentProfile: configuration.activeProfile
        ) else { return }
        let previousConfiguration = configuration
        actionPerformer.releaseAll()
        let settled = VibeKeyAppProfileSwitcher.applySwitch(
            target: target,
            currentProfile: configuration.activeProfile
        ) { [weak self] candidate in
            guard let self else { return false }
            self.configuration.activeProfile = candidate
            return self.persistConfiguration()
        }
        guard settled == target else {
            configuration = previousConfiguration
            refreshUI()
            return
        }
        logger.notice(
            "Profile auto-switched to \(target.rawValue, privacy: .public) for \(bundleID ?? "?", privacy: .public)"
        )
        notice = "已按前台 App 切换到「\(target.displayName)」；离线备用未更动。"
        refreshUI()
    }

    private func syncHardwareFromUI() {
        guard !hardwareSyncInProgress else { return }
        syncHardware(profileID: configuration.activeProfile)
    }

    private func syncHardware(profileID: ProfileID) {
        guard configurationReady else {
            notice = "配置文件无法使用；未写入 AU05。"
            refreshUI()
            return
        }

        guard !hardwareSyncInProgress else { return }

        if let vendor = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.vendorBundleIdentifier
        ).first {
            exitVendorThenSync(vendor: vendor, profileID: profileID)
            return
        }

        continueSyncHardware(profileID: profileID)
    }

    /// Ulanzi Studio holds the AU05 in native mode and conflicts with any
    /// write. Quit it on the user's behalf (graceful first, then force) and
    /// only ask for manual action if it survives both.
    private func exitVendorThenSync(vendor: NSRunningApplication, profileID: ProfileID) {
        hardwareSyncInProgress = true
        vendorInterferedDuringHardwareSync = false
        notice = "Ulanzi Studio 正在运行；正在自动退出它…"
        refreshUI()
        vendor.terminate()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var deadline = Date().addingTimeInterval(4)
            while Date() < deadline, !vendor.isTerminated {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !vendor.isTerminated {
                vendor.forceTerminate()
                deadline = Date().addingTimeInterval(2)
                while Date() < deadline, !vendor.isTerminated {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            let vendorExited = vendor.isTerminated

            DispatchQueue.main.async {
                guard let self else { return }
                self.hardwareSyncInProgress = false
                guard vendorExited else {
                    self.notice = "Ulanzi Studio 未退出；未写入 AU05。"
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Ulanzi Studio 没有退出，无法写入 AU05"
                    alert.informativeText = "Ulanzi Studio 正在接管 AU05，且未能自动退出。请手动完全退出它（程序坞右键图标选「退出」，或 ⌘Q），然后再点一次「离线备用」。"
                    alert.addButton(withTitle: "知道了")
                    alert.runModal()
                    self.refreshUI()
                    return
                }
                self.continueSyncHardware(profileID: profileID)
            }
        }
    }

    private func continueSyncHardware(profileID: ProfileID) {

        let profile = configuration[profileID]
        let hasAppOnlyBindings = profile.indexedControlBindings.contains {
            if case .preset(let action) = $0.binding { return action.isAppOnly }
            return false
        }

        if !needsHardwareSync {
            let previousConfiguration = configuration
            configuration.needsHardwareSync = true
            guard persistConfiguration() else {
                configuration = previousConfiguration
                refreshUI()
                return
            }
            needsHardwareSync = true
        }

        hardwareSyncInProgress = true
        vendorInterferedDuringHardwareSync = false
        if let error = suspendEnhancedMode() {
            hardwareSyncInProgress = false
            notice = "未写入 AU05：\(error.localizedDescription)"
            refreshUI()
            return
        }
        notice = "正在写入「\(profileID.displayName)」原生按键…"
        refreshUI()

        let configurator = hardwareConfigurator
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try configurator.apply(profile: profile)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.hardwareSyncInProgress = false

                switch result {
                case .success:
                    self.offlineStateUnconfirmed = false
                    if self.vendorInterferedDuringHardwareSync
                        || !self.vendorApplicationIsNotRunning {
                        self.configuration.needsHardwareSync = true
                        self.needsHardwareSync = true
                        self.notice = "Ulanzi Studio 在写入时开启；设备内容不确定。请关闭它，再按「离线备用」。"
                        self.presentSyncFailureAlert(
                            "写入过程中 Ulanzi Studio 开启了，设备内容不确定。请完全退出 Ulanzi Studio，再点一次「离线备用」。"
                        )
                    } else if let markerSaveError = self.completeHardwareSync(profileID: profileID) {
                        self.notice = "已写入「\(profileID.displayName)」，但同步狀态保存失败：\(markerSaveError) 下次启动会再写一次。"
                    } else if hasAppOnlyBindings {
                        self.notice = "已写入「\(profileID.displayName)」：关掉 App 仍可使用。App 专属键（语音／Fn 双擊）离线為空，該键需 App 执行。"
                    } else {
                        self.notice = "已写入「\(profileID.displayName)」：关掉 App 仍可使用。"
                    }
                    self.logger.notice(
                        "Hardware profile \(profileID.rawValue, privacy: .public) written successfully"
                    )
                    if !self.needsHardwareSync,
                       !self.listenerActive,
                       self.enhancedModeRequested {
                        self.startHardwareListener(promptForPermission: true)
                    }
                case let .failure(error):
                    if let configurationError = error as? IOKitHardwareConfiguratorError {
                        switch configurationError {
                        case .offlineWriteFailed:
                            self.offlineStateUnconfirmed = true
                            self.notice = "同步中止：\(error.localizedDescription) 六键尚未开始写入；请保持连接再试。"
                        case .reportWriteFailed:
                            self.offlineStateUnconfirmed = false
                            self.notice = "同步失败：\(error.localizedDescription) 设备可能只写入部分；请保持连接，再按「离线备用」。"
                        default:
                            self.notice = "同步中止：\(error.localizedDescription) 六键尚未开始写入。"
                        }
                    } else {
                        self.notice = "同步失败：\(error.localizedDescription)"
                    }
                    self.presentSyncFailureAlert(self.notice ?? "同步失败。")
                    self.logger.error(
                        "Hardware profile write failed: \(error.localizedDescription, privacy: .public)"
                    )
                }

                self.refreshUI()
            }
        }
    }

    private static let vendorBundleIdentifier = "ulanzi.UlanziStudio"

    /// User-visible guidance when the offline write does not complete. The
    /// button no longer confirms before writing; failing after the fact is
    /// when the user needs a dialog.
    private func presentSyncFailureAlert(_ guidance: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「离线备用」没有完成"
        alert.informativeText = guidance
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private var launchAtLoginStatusEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            do {
                try service.unregister()
            } catch {
                notice = "关闭开机自启失败：\(error.localizedDescription)"
            }
        default:
            do {
                try service.register()
                notice = "已开启开机自启；下次重启后 VibeKey Lite 会自动运行。"
            } catch {
                notice = "开启开机自启失败：\(error.localizedDescription)"
            }
        }
        refreshUI()
    }

    private var vendorApplicationIsNotRunning: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.vendorBundleIdentifier
        ).isEmpty
    }

    private var onlinePreflightIsValid: Bool {
        guard configurationReady,
              enhancedModeRequested,
              configuration.offlineProfile != nil,
              !needsHardwareSync,
              vendorApplicationIsNotRunning,
              IOHIDListenAccess.isGranted,
              AccessibilityAccess.isTrusted(promptForPermission: false) else {
            return false
        }
        return (try? validateAllProfilesForOnlineMode()) != nil
    }

    private func validateAllProfilesForOnlineMode() throws {
        try actionPerformer.validate(profile: configuration.profileA)
        try actionPerformer.validate(profile: configuration.profileB)
    }

    private func completeHardwareSync(profileID: ProfileID) -> String? {
        guard let configStore else {
            return "配置文件位置不可用。"
        }

        let previousOfflineProfile = configuration.offlineProfile
        configuration.offlineProfile = profileID
        configuration.needsHardwareSync = false
        do {
            try configStore.save(configuration)
            needsHardwareSync = false
            return nil
        } catch {
            configuration.offlineProfile = previousOfflineProfile
            configuration.needsHardwareSync = true
            needsHardwareSync = true
            return error.localizedDescription
        }
    }

    @discardableResult
    private func persistConfiguration() -> Bool {
        guard let configStore else {
            notice = "配置文件位置不可用，这次变更尚未保存。"
            return false
        }

        do {
            try configStore.save(configuration)
            if notice?.contains("尚未保存") == true || notice?.hasPrefix("配置文件") == true {
                notice = nil
            }
            return true
        } catch {
            notice = "配置文件保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func refreshUI() {
        refreshStatusItem()
        settingsViewController?.update(
            configuration: configuration,
            listenerActive: listenerActive,
            accessibilityGranted: accessibilityGranted,
            deviceConnected: deviceConnected,
            powerStatus: devicePowerStatus,
            powerSaving: powerSaving,
            hardwareSyncInProgress: hardwareSyncInProgress,
            launchAtLoginEnabled: launchAtLoginStatusEnabled,
            notice: notice
        )
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }

        let profileName = configuration.activeProfile.displayName
        let batteryDescription = devicePowerStatus.battery.map {
            "，電量 \($0.percent)%"
        } ?? ""
        let accessibleName = "VibeKey Lite：\(profileName)\(batteryDescription)"
        let preferredSymbol = configuration.activeProfile == .a
            ? "sparkles"
            : "slider.horizontal.3"
        let image = VibeKeyStatusIcon.image(for: configuration.activeProfile) ?? NSImage(
            systemSymbolName: preferredSymbol,
            accessibilityDescription: nil
        ) ?? NSImage(
            systemSymbolName: "dial.medium",
            accessibilityDescription: nil
        )

        button.toolTip = accessibleName
        button.setAccessibilityLabel(accessibleName)

        if let image {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = "VK"
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard statusItem?.button != nil, let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button,
              let popover,
              !popover.isShown else { return }
        resumeAfterUserActivityIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hardwareListener?.refreshPowerStatus()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
