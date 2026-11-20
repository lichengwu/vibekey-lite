# VibeKey Lite 开发方案（2026-11-18）

> 基于《VibeKey (Ulanzi AU05) 自建工具开发交接文档》（2026-11-10/18 排查产物）补充本次代码核实后的实施方案。
> 硬约束：**设备不能变砖**。所有方案按风险分级，设备写入仅限已验证的低风险命令组。

---

## 0. 本次代码核实结论（交接文档之外的增量）

| 项 | 结论 | 证据位置 |
| --- | --- | --- |
| 仓库状态 | `main` 与 `origin/main` 同步于 `43fb901`，工作区干净 | git status |
| 上游可靠性修复 | 近期提交 `Recover AU05 connection after Mac reboot` / `Recover after controller standby and power off` / `Do not postpone standby on status refresh` 修的正是按键失灵类问题，**动工前先合并 upstream** | git log |
| ProfileID | 两值 String 枚举 `case a / case b`（`Models.swift:3`），Codable + String raw value → 加新 case 向后兼容旧 config.json；但 `toggled` 与 SettingsViewController 双态假设需要动 | Models.swift:3-17 |
| NSWorkspace 监听先例 | `configureLifecycleObservers()` 已监听 willSleep/willPowerOff，M1 照此模式加 `didActivateApplication` | AppDelegate.swift:263-285 |
| activeProfile 切换现成路径 | `:127-133` 已有「设 activeProfile → persistConfiguration → 失败回滚」，M1 复用 | AppDelegate.swift:127-133 |
| LED 协议 | group `0x0B` / command `0x88`，7 个 fieldMask（0x01/02/04/08/10/20/40），4 灯独立（ledIndex 0-3），per-LED 记录起始 offset 8、每灯 5 字节。文档明示 "Start with GET/readback and low-risk values" | docs/protocol.md:272-297 |

---

## 1. 风险分级与防砖红线

### 🟢 零风险（纯软件，不碰设备）
- 所有 Swift 代码改动、config.json 变更
- CGEvent 快捷键注入、NSWorkspace 前台监听
- CodeBuddy/WorkBuddy hooks 调用

### 🟡 低风险（设备写入，出错可恢复）
- **LED 灯控**（group `0x0B`，command `0x88`）：独立灯控区，不碰固件区。写错最多灯不亮/节奏不对，GET 读回即恢复，拔插 dongle 兜底
- **六格离线写入**：已实测验证过配置写入成功；但属于设备存储区，写后必须 GET 读回校验

### 🔴 禁止（变砖/不可逆风险）
- 固件升级 / OTA（vendor 签名固件包）
- 首次配对 / 解绑
- 出厂重置
- 降噪模式设置（DSP 在固件内，协议未见）
- 一切非 `0x0B` 灯控组的**未知命令写入**（GET 读取类命令不限）

### 硬性测试纪律
1. 任何 SET 前先 GET 快照原始值，测试结束恢复原值
2. 六格写入后 GET 读回校验，快照存档（`~/Library/Application Support/VibeKeyLite/snapshots/`）
3. 所有设备写入封装「值域校验 → 发送 → GET 验证」三步，未知值直接拒发
4. 探针测试期间退出 Ulanzi Studio（两个 host 抢设备会打架）
5. 异常兜底顺序：GET 恢复原值 → 重启 Lite → 拔插 dongle → （仅固件异常才考虑）Studio 重连

---

## 2. M1：按前台 App 自动切 profile

### 方案 A（推荐首做，~100 行，不改枚举）

config.json 只加 bundleID → 现有两 profile 的映射，其余全复用。

**改动点：**
1. `Sources/VibeKeyLiteCore/Models.swift`：AppConfiguration 加 `appProfileMapping: [String: ProfileID]`（bundleID → .a/.b），默认空
2. `Sources/VibeKeyLite/AppDelegate.swift`：
   - `configureLifecycleObservers()` 加 `NSWorkspace.didActivateApplicationNotification` 监听
   - 回调里取 `NSRunningApplication.frontmostApplication?.bundleIdentifier`，查映射表，命中且 ≠ 当前 profile → 走 `:127-133` 的现成切换路径
   - 防抖：同一 App 重复激活不触发（现有 `guard profile != self.configuration.activeProfile` 已天然防重）
3. 启动时读一次前台 App，避免开机后第一次切换前用错组

**边界情况：**
- 映射未命中的 App：保持当前 profile 不变（不自动回退，避免来回跳）
- App 切换风暴（Mission Control/快速 ⌘Tab）：`didActivateApplication` 本身有节流，必要时加 200ms 防抖
- full-screen App 切换、Spotlight 临时焦点：按 bundleID 判断自然过滤

### 方案 B（后续升级，N-profile）

- `ProfileID` 枚举加 case（rawValue String 向后兼容）
- `toggled` 语义改为「下一个 profile」或废弃，改由映射表/UI 指定
- SettingsViewController 的双态 UI 改为列表编辑器（最大工作量所在）
- **建议等方案 A 跑稳一周后再做**

---

## 3. M2：自建 Agent 状态灯效

### 3.1 架构

```
agent hooks (CodeBuddy 9事件 / WorkBuddy / 任意程序)
        │ 调 CLI
        ▼
vibekeyctl led --state <thinking|working|attention|idle|error|off> [--led N]
        │ 本地 socket 或直接进程内
        ▼
VibeKeyLite（常驻，持有 USB HID 连接）
        │ 0x0B/0x88 LED 命令
        ▼
AU05 设备（4 LED）
```

推荐**把 CLI 做成 Lite App 的一个子命令**（App 已持有 HID 连接和权限，避免两个进程抢设备）。

### 3.2 状态映射（初版，探针后可调）

| 状态 | 期望灯效 | 参数来源 |
| --- | --- | --- |
| thinking | 呼吸 | breatheLevel/breatheBrightness |
| working | 常亮（中亮） | workType=Solid + 常亮亮度 |
| attention | 快闪 | workType 待探针确认（若 0/2 为闪型）或软件定时器翻转 |
| error | 高亮告警 | 全灯最亮常亮 |
| idle | 微亮 | 常亮亮度最低档 |
| off | 熄灭 | 亮度 0 |

### 3.3 前置：硬件探针测试（约 30 分钟，需用户配合）

目的：把 protocol.md 标 "needs hardware test" 的字节全部摸清，结果写回文档。

**探针清单（每组都是 GET → SET → 观察确认 → 继续）：**
1. LED index ↔ 物理灯对应（0-3 各设一个可辨识状态）
2. workType 0/1/2 语义（1=Solid 已实锤；0、2 逐个试）
3. 呼吸等级 breatheLevel 值域（已知 2 有效）与呼吸亮度 breatheBrightness 值域
4. 常亮亮度值域（已知 7 有效，allOn 亮度 16 有效）
5. workTime 单位与值域（已知 10 有效）
6. 全局模式 currentMode 0/1/2 的实际表现差异（注意：切到 2 后官方 Studio 停推灯效，需确认自建不受影响）

**测试脚本形式**：做成 `vibekeyctl probe` 子命令，逐项交互式执行（发一条 → 等用户口述现象 → 记录 → 下一条），全部完成后自动恢复 GET 快照原值。

### 3.4 与官方 Studio 的共存

- 测试与日常运行期间退出 Studio（交接文档 §2.3 分工：Studio 只在固件升级/配对/降噪时开）
- Studio 的「灯效三档」全局模式与自建灯效会互相覆盖，以谁最后写入为准——日常只用 Lite 后此问题自然消失

---

## 4. M3：可选扩展（均零设备固件风险）

1. `ActionPerformer.swift` 扩展动作类型：shell 命令、AppleScript、打开 URL、多项顺序执行
2. 切 profile 时同步刷新六格离线备用组（快照自动化）
3. 按前台 App 联动灯效（App 活跃 → LED 特定颜色/模式提示，与 M1 共用同一个监听）
4. WorkBuddy 深度联动：WorkBuddy 会话状态（排队/执行中/需确认/完成）→ 灯效 + 按键（如「需确认」时旋钮单击=批准）

---

## 5. 实施顺序与里程碑

| 阶段 | 内容 | 风险 | 依赖 | 实际状态（2026-11-20） |
| --- | --- | --- | --- | --- |
| M0 | 合并 upstream 可靠性修复 + 验证当前构建能跑 | 🟢 | 用户授权输入监控/辅助使用 | ✅ 完成 |
| M1 | 方案 A：bundleID→profile 自动切换 | 🟢 | 用户提供映射表 | ✅ 代码完成（appProfileMapping + 200ms 防抖 + 启动读前台 + 9 单测）；映射表默认空，待用户提供 |
| M2-pre | LED 硬件探针 | 🟡 | 用户配合观察 | ✅ 完成，两次修正结论见 protocol.md（全量载荷 + workTime=255 闸门；idx0 固件自驱不可控） |
| M2 | 状态灯效 CLI + hooks 接入 | 🟡 | M2-pre 结果 | ✅ S1-S5 代码完成（140+ 单测）；六状态真机验收基本通过，thinking 隔离复测待用户确认；QwenWork loopback 监听未实现（UI 引导已就位） |
| M3 | 按需选做 | 🟢/🟡 | M1 | 未开始 |

每阶段完成即 commit 到自己的 fork（origin 已是 SSH 可 push）。

---

## 6. 用户配合清单

| # | 事项 | 时机 | 耗时 |
| --- | --- | --- | --- |
| 1 | 拍板 M1 走方案 A 或 B | 现在 | 1 分钟 |
| 2 | LED 硬件探针：逐条看灯效并口述现象（哪颗灯/什么节奏） | M2 前 | ~30 分钟 |
| 3 | 提供 App→profile/动作映射表 | M1 配置时 | 10 分钟 |
| 4 | 真机按键验收（按键是物理的，只能人按） | 每轮构建后 | 2 分钟/次 |
| 5 | 新构建首次运行的两项系统授权 | M0/首次运行 | 1 分钟 |
| 6 | 测试期间退出 Ulanzi Studio；设备保持插 dongle、电量充足 | 全程 | — |
