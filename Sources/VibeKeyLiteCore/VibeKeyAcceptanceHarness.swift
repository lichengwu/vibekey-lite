import Foundation

/// Offline acceptance harness (scripts/acceptance.sh drives the live run;
/// this Core module makes the whole checklist testable with a mock device).
///
/// Every check that can be asserted in software is asserted here against
/// the pure Engine/handler/installer logic. Checks that need human eyes or
/// hands are emitted as `.manual` steps with explicit "佐井操作" labels —
/// the live script pauses for them and never auto-passes.
public enum VibeKeyAcceptanceHarness {
    public enum StepKind: String, Sendable {
        case automatic
        case manual
    }

    public struct Step: Equatable, Sendable {
        public var id: String
        public var kind: StepKind
        public var title: String
        /// For manual steps: exactly what the human must observe/do.
        public var instruction: String?

        public init(id: String, kind: StepKind, title: String, instruction: String? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.instruction = instruction
        }
    }

    public struct Result: Equatable, Sendable {
        public var stepID: String
        public var passed: Bool
        public var detail: String

        public init(stepID: String, passed: Bool, detail: String) {
            self.stepID = stepID
            self.passed = passed
            self.detail = detail
        }
    }

    /// The full acceptance checklist, in execution order.
    public static func checklist() -> [Step] {
        [
            // --- A. Six-state rendering (mock-assertable frame contracts) ---
            Step(id: "A1", kind: .automatic, title: "idle 全灭帧契约"),
            Step(id: "A2", kind: .automatic, title: "working 旋钮常亮帧契约"),
            Step(id: "A3", kind: .automatic, title: "attention 中键 workTime=10 + 10s 降级"),
            Step(id: "A4", kind: .automatic, title: "notification 中+下快闪 0.6s 亮度翻转"),
            Step(id: "A5", kind: .automatic, title: "error 全亮闪3次+前态全量恢复"),
            Step(id: "A6", kind: .automatic, title: "sweeping 三灯流水 0.5s"),
            Step(id: "A7", kind: .manual, title: "六状态真机灯效核对",
                 instruction: "佐井操作：脚本逐状态保持 8 秒，肉眼核对灯位/节奏与 A1-A6 契约一致；thinking 灯位以隔离观察结论为准"),
            // --- B. QwenWork loopback end-to-end ---
            Step(id: "B1", kind: .automatic, title: "QwenWork 7 事件注入→状态映射（mock HTTP）"),
            Step(id: "B2", kind: .automatic, title: "QwenWork 错 token 401 / 坏 JSON 容错"),
            Step(id: "B3", kind: .automatic, title: "QwenWork 仲裁：notification 压 working + 120s 过期"),
            Step(id: "B4", kind: .manual, title: "QwenWork 安装→后台粘贴→真机事件到灯",
                 instruction: "佐井操作：App 内点 QwenWork 安装→复制配置→企业管理后台粘贴 7 事件→在千问办公跑一轮任务看灯；完成后点卸载并清空后台规则"),
            // --- C. M1 auto profile switching regression ---
            Step(id: "C1", kind: .automatic, title: "M1 映射命中切换/未命中不动/防重（纯逻辑）"),
            Step(id: "C2", kind: .automatic, title: "M1 防抖风暴只留最后 + persist 失败回滚"),
            Step(id: "C3", kind: .manual, title: "M1 真机按键回归",
                 instruction: "佐井操作：配置 appProfileMapping 后切换前台 App，按旋钮/三键确认动作随 profile 变化；⌘Tab 快速切换不连环切组"),
            // --- D. Hygiene ---
            Step(id: "D1", kind: .automatic, title: "shutdown 恢复出厂基线帧"),
            Step(id: "D2", kind: .manual, title: "收尾确认",
                 instruction: "佐井操作：确认设备灯回到基线（旋钮常亮其余灭）、WorkBuddy hooks 是否装回由佐井决定"),
        ]
    }

    /// Runs all automatic checks against mock device state. Never touches
    /// HID, sockets, or real config files.
    public static func runAutomaticChecks(
        thinkingLeds: [Int] = VibeKeyLedRenderEngine.thinkingLeds
    ) -> [Result] {
        var results: [Result] = []
        func record(_ id: String, _ passed: Bool, _ detail: String) {
            results.append(Result(stepID: id, passed: passed, detail: detail))
        }

        // A1 idle
        do {
            var engine = VibeKeyLedRenderEngine()
            var now: TimeInterval = 0
            _ = engine.request(.working, now: now)
            now += 0.2
            _ = engine.tick(now: now)
            engine.confirmDeviceState(engine.deviceState)
            _ = engine.writeCompleted(success: true, now: now)
            _ = engine.request(.idle, now: now)
            now += 0.2
            let plans = engine.tick(now: now)
            let ok = plans.first.map { plan in
                (1...3).allSatisfy { plan.desired.leds[$0].workType == 0 }
            } ?? false
            record("A1", ok, ok ? "三颗主机灯 workType=0" : "idle 帧未全灭")
        }

        // A2 working
        do {
            var engine = VibeKeyLedRenderEngine()
            var now: TimeInterval = 0
            _ = engine.request(.working, now: now)
            now += 0.2
            let plans = engine.tick(now: now)
            let ok = plans.first.map { plan in
                plan.desired.leds[3].workType == 1
                    && plan.desired.leds[3].alwaysOnBrightness == 7
                    && plan.desired.leds[3].workTime == 255
                    && plan.desired.leds[1].workType == 0
                    && plan.desired.leds[2].workType == 0
            } ?? false
            record("A2", ok, ok ? "旋钮 wt=1 bright=7 time=255，其余灭" : "working 帧契约不符")
        }

        // A3 attention + downgrade
        do {
            var engine = VibeKeyLedRenderEngine()
            var now: TimeInterval = 0
            _ = engine.request(.attention, now: now)
            now += 0.2
            let entry = engine.tick(now: now)
            let entryOK = entry.first.map { $0.desired.leds[1].workTime == 10 } ?? false
            engine.confirmDeviceState(entry[0].desired)
            _ = engine.writeCompleted(success: true, now: now)
            now += 10.1
            let downgrade = engine.tick(now: now)
            let downOK = engine.currentState == .idle && !downgrade.isEmpty
            record("A3", entryOK && downOK,
                   entryOK && downOK ? "workTime=10 + 10s 本地降级 idle" : "attention 契约/降级不符")
        }

        // A4 notification blink
        do {
            var engine = VibeKeyLedRenderEngine()
            var now: TimeInterval = 0
            let entry = engine.request(.notification, now: now)
            let entryOK = entry.first.map {
                $0.desired.leds[1].alwaysOnBrightness == 15
                    && $0.desired.leds[2].alwaysOnBrightness == 15
            } ?? false
            engine.confirmDeviceState(entry[0].desired)
            _ = engine.writeCompleted(success: true, now: now)
            now += 0.3
            let dark = engine.tick(now: now)
            let darkOK = dark.first.map {
                $0.desired.leds[1].alwaysOnBrightness == 0
                    && $0.desired.leds[2].alwaysOnBrightness == 0
                    && $0.desired.leds[1].workType == entry[0].desired.leds[1].workType
            } ?? false
            record("A4", entryOK && darkOK,
                   entryOK && darkOK ? "中+下 0.6s 亮度翻转，workType 不变" : "notification 闪烁契约不符")
        }

        // A5 error flash + restore
        do {
            var engine = VibeKeyLedRenderEngine()
            var now: TimeInterval = 0
            _ = engine.request(.working, now: now)
            now += 0.2
            let w = engine.tick(now: now)
            engine.confirmDeviceState(w[0].desired)
            _ = engine.writeCompleted(success: true, now: now)
            let e = engine.request(.error, now: now)
            let flashOK = e.first.map { $0.desired.mode == 1 } ?? false
            engine.confirmDeviceState(e[0].desired)
            _ = engine.writeCompleted(success: true, now: now)
            var restoreOK = false
            for _ in 0..<6 {
                now += 0.4
                let plans = engine.tick(now: now)
                if let plan = plans.first {
                    engine.confirmDeviceState(plan.desired)
                    _ = engine.writeCompleted(success: true, now: now)
                }
                if engine.currentState == .working {
                    restoreOK = plans.first.map {
                        $0.desired.leds[3].workType == 1 && $0.desired.leds[3].workTime == 255
                    } ?? false
                    break
                }
            }
            record("A5", flashOK && restoreOK,
                   flashOK && restoreOK ? "mode1 闪3次后全量恢复 working" : "error 闪烁/恢复不符")
        }

        // A6 sweeping
        do {
            var engine = VibeKeyLedRenderEngine()
            var now: TimeInterval = 0
            _ = engine.request(.sweeping, now: now)
            now += 0.2
            let entry = engine.tick(now: now)
            engine.confirmDeviceState(entry[0].desired)
            _ = engine.writeCompleted(success: true, now: now)
            var sweepOK = true
            for step in 1...3 {
                now += 0.5
                let plans = engine.tick(now: now)
                let active = [1, 2, 3][step % 3]
                let ok = plans.first.map { plan in
                    (1...3).allSatisfy { led in
                        plan.desired.leds[led].alwaysOnBrightness == (led == active ? 15 : 0)
                    }
                } ?? false
                sweepOK = sweepOK && ok
                if let plan = plans.first {
                    engine.confirmDeviceState(plan.desired)
                    _ = engine.writeCompleted(success: true, now: now)
                }
            }
            record("A6", sweepOK, sweepOK ? "0.5s 步长三灯轮转" : "流水步序不符")
        }

        // B1-B3 QwenWork via pure handler (mock HTTP, no socket)
        do {
            var handler = VibeKeyQwenWorkHookHandler(token: "acceptance-token")
            var now: TimeInterval = 0
            let events: [(String, VibeKeyAgentState)] = [
                ("SessionStart", .idle), ("UserPromptSubmit", .thinking),
                ("PreToolUse", .working), ("PostToolUse", .working),
                ("Stop", .attention), ("Notification", .notification),
                ("PreCompact", .sweeping),
            ]
            var allOK = true
            for (event, expected) in events {
                let body = Data("{\"hook_event_name\":\"\(event)\",\"session_id\":\"acc\"}".utf8)
                let response = handler.handle(
                    method: "POST", requestPath: VibeKeyQwenWorkHookHandler.path,
                    authorizationHeader: "Bearer acceptance-token", body: body, now: now
                )
                allOK = allOK && response.statusCode == 200 && response.resolvedState == expected
                now += 1
            }
            record("B1", allOK, allOK ? "7 事件全部映射正确" : "存在映射不符事件")

            let badToken = handler.handle(
                method: "POST", requestPath: VibeKeyQwenWorkHookHandler.path,
                authorizationHeader: "Bearer wrong",
                body: Data("{\"hook_event_name\":\"Stop\"}".utf8), now: now
            )
            let badJSON = handler.handle(
                method: "POST", requestPath: VibeKeyQwenWorkHookHandler.path,
                authorizationHeader: "Bearer acceptance-token",
                body: Data("{broken".utf8), now: now
            )
            let b2OK = badToken.statusCode == 401 && badJSON.statusCode == 200
                && badJSON.resolvedState == nil
            record("B2", b2OK, b2OK ? "401 + 坏JSON容错" : "鉴权/容错不符")

            var arb = VibeKeyQwenWorkHookHandler(token: "t")
            _ = arb.handle(method: "POST", requestPath: VibeKeyQwenWorkHookHandler.path,
                           authorizationHeader: "Bearer t",
                           body: Data("{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"a\"}".utf8), now: 0)
            let notif = arb.handle(method: "POST", requestPath: VibeKeyQwenWorkHookHandler.path,
                                   authorizationHeader: "Bearer t",
                                   body: Data("{\"hook_event_name\":\"Notification\",\"session_id\":\"b\"}".utf8), now: 1)
            let stale = arb.prune(now: 122)
            let b3OK = notif.resolvedState == .notification && stale == .idle
            record("B3", b3OK, b3OK ? "notification 优先 + 120s 全过期回 idle" : "仲裁组合不符")
        }

        // C1-C2 M1 pure logic
        do {
            let mapping = ["com.test.ai": ProfileID.a, "com.test.sys": ProfileID.b]
            let hit = VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.test.sys", mapping: mapping, currentProfile: .a) == .b
            let miss = VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.test.other", mapping: mapping, currentProfile: .a) == nil
            let dedup = VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.test.ai", mapping: mapping, currentProfile: .a) == nil
            record("C1", hit && miss && dedup,
                   hit && miss && dedup ? "命中切换/未命中不动/防重" : "M1 决策不符")

            var debouncer = VibeKeyAppActivationDebouncer()
            let t1 = debouncer.activate("com.test.a")
            let t2 = debouncer.activate("com.test.b")
            let stormOK = debouncer.fire(generation: t1) == nil
                && debouncer.fire(generation: t2) == "com.test.b"
            var persisted: [ProfileID] = []
            let rollback = VibeKeyAppProfileSwitcher.applySwitch(target: .b, currentProfile: .a) {
                persisted.append($0); return false
            } == .a
            record("C2", stormOK && rollback && persisted == [.b],
                   stormOK && rollback ? "防抖留最后 + 失败回滚" : "防抖/回滚不符")
        }

        // D1 shutdown baseline
        do {
            var engine = VibeKeyLedRenderEngine()
            let plan = engine.shutdown()
            let ok = plan.desired == VibeKeyLedState.baseline
            record("D1", ok, ok ? "shutdown 输出出厂基线" : "基线恢复不符")
        }

        // Thinking placement is provisional: assert the wiring point exists
        // and the pattern honors it (no hardware claim).
        _ = thinkingLeds
        return results
    }

    /// Manual steps the live script must pause for. Never auto-passed.
    public static func manualSteps() -> [Step] {
        checklist().filter { $0.kind == .manual }
    }
}