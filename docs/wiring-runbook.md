# 接线 Runbook（灯观察结论回来后，5 分钟走完）

> 前提：代码已 delivered（222 测全绿、已 push）。唯一技术卡点 = 佐井的 thinking 灯观察。
> 本 runbook 两种结论分支都已预写测试并**实际演练过**（branch B 翻转后全套绿，已还原）。
> 配套：docs/delivery-checklist.md（完整步骤）、docs/OWNER-ACTIONS.md（佐井决策清单）。

## 第 0 步：拿到观察结论（佐井，1 分钟）

纯净环境（WorkBuddy hooks 当前已卸载）下执行：
```sh
"/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl" led --state thinking
```
盯设备 15 秒，回答：**慢闪的是旋钮，还是中键+下键？**
（若灯被"中+下快闪"抢走，说明有真实 hooks 事件在跑——先确认 hooks 卸载状态：`vibekeyctl detect`。）

## 第 1 步：改常量（agent，30 秒）

**唯一接线点**：`Sources/VibeKeyLiteCore/VibeKeyLedRenderEngine.swift:48`

| 结论 | 改为 | 同步改的守卫断言 |
| --- | --- | --- |
| A：旋钮 | `[3]`（保持不动） | 无需改 |
| B：中+下 | `[1, 2]` | `Tests/VibeKeyLiteCoreTests/VibeKeyLedPatternTests.swift` 中 `testThinkingCurrentProvisionalValueIsKnob` 的 `XCTAssertEqual(..., [3])` → `[1, 2]`（建议顺手把测试名改为 ...IsMiddleBottom） |

其余**零改动**：Pattern/Engine/薄壳/验收 harness 全部接线点无关（已演练验证）。
分支 B 一键命令（已演练过）：
```sh
perl -pi -e 's/public static let thinkingLeds: \[Int\] = \[3\]/public static let thinkingLeds: [Int] = [1, 2]/' Sources/VibeKeyLiteCore/VibeKeyLedRenderEngine.swift
perl -pi -e 's/XCTAssertEqual\(VibeKeyLedRenderEngine.thinkingLeds, \[3\]\)/XCTAssertEqual(VibeKeyLedRenderEngine.thinkingLeds, [1, 2])/' Tests/VibeKeyLiteCoreTests/VibeKeyLedPatternTests.swift
```

## 第 2 步：测试（agent，30 秒）
```sh
swift test --disable-sandbox   # 必须 222/222 全绿（Core 217 + App 5）
```
预写保障：`testThinkingWiringPointIsOneOfTwoConfirmedCandidates`（两候选都绿）、`testThinkingPatternFollowsWiringPoint`（跟随常量）、两分支完整契约测试、Engine 闪烁测试已改为接线点无关。

## 第 3 步：打包（agent，1 分钟，无需放行）
```sh
VIBEKEY_SIGNING_IDENTITY=F7FBEA12E4E4DB3128C39311E8AF83984FD86460 ./build-app.sh
codesign --verify --strict ".build/app/VibeKey Lite.app"
```

## 第 4 步：替换安装版（👤 佐井放行后 agent 执行，1 分钟）
```sh
osascript -e 'tell application "VibeKey Lite" to quit'
sleep 1
ditto ".build/app/VibeKey Lite.app" "/Applications/VibeKey Lite.app"
open "/Applications/VibeKey Lite.app"
sleep 3
"/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl" status   # 应 state=idle
```

## 第 5 步：live 验收（佐井操作 + agent 驱动，2 分钟）
```sh
./scripts/acceptance.sh live
```
A7 六状态核对（thinking 按新结论）；B4/C3 可跳过（输入 s）；D2 收尾。

## 第 6 步：装回 WorkBuddy hooks（👤 佐井放行后 agent 执行，10 秒）
```sh
"/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl" install-hooks --agent codebuddy
```
原有 hindsight hooks 不受影响（只增不删+自动备份）。装回后在 WorkBuddy 跑一轮任务，灯随状态变即端到端闭环。

## 第 7 步：commit + push（agent；push 已获长期放行）
按功能拆 commit（英文 message），`git push origin main`。

---

## 演练记录（2026-11-21）
- Branch B 实际翻转演练：常量+守卫改 [1,2] → **222/222 全绿** → 还原 [3] → 再验全绿。
- 结论：两种分支都是"改两处（常量+守卫断言）→ 测试 → 打包"，无结构性工作。