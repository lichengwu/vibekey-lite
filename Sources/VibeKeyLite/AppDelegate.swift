import AppKit
import OSLog
import VibeKeyLiteCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hardwareConfigurator: any HardwareConfigurator
    private var configuration = AppConfiguration.default
    private var configStore: ConfigStore?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsViewController: SettingsViewController?
    private var hardwareListener: IOKitHardwareListener?
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
        configureLifecycleObservers()
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
            self?.confirmAndSyncHardware()
        }
        settings.onToggleEnhancedMode = { [weak self] in
            self?.toggleEnhancedMode()
        }
        settings.onQuit = {
            NSApplication.shared.terminate(nil)
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
            notice = "Ulanzi Studio 执行中；已保留 AU05 原生模式。"
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

    private func confirmAndSyncHardware() {
        guard !hardwareSyncInProgress else { return }
        let profileID = configuration.activeProfile

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要重写目前这组 6 个原生按键吗？"
        alert.informativeText = "这会把「\(profileID.displayName)」的完整六格写入 AU05；关掉 VibeKey Lite 后仍可使用。"
        alert.addButton(withTitle: "同步")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        syncHardware(profileID: profileID)
    }

    private func syncHardware(profileID: ProfileID) {
        guard configurationReady else {
            notice = "配置文件无法使用；未写入 AU05。"
            refreshUI()
            return
        }

        guard !hardwareSyncInProgress else { return }

        let vendorBundleIdentifier = "ulanzi.UlanziStudio"
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: vendorBundleIdentifier
        ).isEmpty else {
            notice = "请先完全结束 Ulanzi Studio，再同步到设备。"
            refreshUI()
            return
        }

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
                        self.notice = "Ulanzi Studio 在写入时开启；设备內容不确定。请关閉它，再按「离线备用」。"
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
                            self.notice = "同步中止：\(error.localizedDescription) 六键尚未开始写入；请保持连接再試。"
                        case .reportWriteFailed:
                            self.offlineStateUnconfirmed = false
                            self.notice = "同步失败：\(error.localizedDescription) 设备可能只写入部分；请保持连接，再按「离线备用」。"
                        default:
                            self.notice = "同步中止：\(error.localizedDescription) 六键尚未开始写入。"
                        }
                    } else {
                        self.notice = "同步失败：\(error.localizedDescription)"
                    }
                    self.logger.error(
                        "Hardware profile write failed: \(error.localizedDescription, privacy: .public)"
                    )
                }

                self.refreshUI()
            }
        }
    }

    private var vendorApplicationIsNotRunning: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "ulanzi.UlanziStudio"
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
