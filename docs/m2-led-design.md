# M2 灯效系统设计（2026-11-20）

> 前置：协议破解已完工（docs/protocol.md「workTime is the render gate」+「Voice-key LED final verdict」）。
> 本文是实施设计，经用户确认后动工。硬约束沿用 dev-plan.md §1：只写 0x0B/0x88 灯控组，值域校验 → 发送 → GET 读回。

## 1. 硬件能力基线（实测锁定，不再探索）

| 能力 | 结论 |
| --- | --- |
| 可控灯 | idx1=中键、idx2=下键、idx3=旋钮，三颗独立常亮开/关 |
| 不可控 | idx0=语音键（固件按键反馈灯，松开闪一下，留给固件） |
| 常亮前提 | 全局 mode=2 + 全量四灯载荷 + workTime=255（mask 0x08 专用帧） |
| 自动熄灭 | workTime=10 → 亮约 10 秒自动灭（**当"完成提示"用，是特性不是 bug**） |
| 呼吸 | wt=2 本机不渲染 → 一切"呼吸/闪烁"用软件定时器翻转 wt=1/0 模拟 |
| 全局开关 | mode 0=全灭、1=全亮（会点亮语音键，用作高优先告警） |
| 渲染触发 | 每次状态变化必须发新写入；相同状态重发无效果 |
| 亮度 | 0..20，日常 7，告警 15 |

## 2. 状态 → 灯效映射（v1）

事件→状态映射直接采用官方 ustudio-cli mappings.js（9 种 Agent 已覆盖，见 protocol.md）。

| 状态 | 触发事件（官方映射） | 灯效 | 实现 |
| --- | --- | --- | --- |
| idle | SessionStart / AfterAgent | 全灭 | mode2 + 三灯 wt=0 |
| thinking | UserPromptSubmit | 旋钮慢闪（1.2s 周期） | 软件定时器翻转 idx3 |
| working | PreToolUse / PostToolUse / Subagent* | 旋钮常亮（亮度 7） | idx3 wt=1, workTime=255 |
| attention | Stop（回合完成） | 中键亮 10 秒自动灭 | idx1 wt=1, **workTime=10**（利用固件自动熄灭） |
| notification | Notification / PermissionRequest（需审批） | 中+下快闪（0.4s 周期） | 定时器翻转 idx1+idx2 |
| error | *Failure | 全局全亮闪 3 次后回前态 | mode 1/0 交替 ×3 |
| sweeping | PreCompact（压缩上下文） | 三灯流水（每 0.3s 移位） | 定时器轮转 idx1→2→3 |
| sleeping | SessionEnd | 全灭 | 同 idle |
| off | 手动 | 全灭并停用灯效 | 渲染器挂起 |

设计原则：
- **旋钮=Agent 心跳**（在动=慢闪，干活=常亮），**中键=完成**，**下键参与=需要你**—— peripheral vision 一眼分级。
- 需审批（notification）是唯一持续快闪的状态，最扎眼，符合"人在回路"最高优先。
- attention 用 workTime=10 的固件自动熄灭，省一个定时器，且"完成提示"天然限时。

### 2.1 Review 修正（2026-11-20 晚）

| # | 原设计问题 | 修正 |
| --- | --- | --- |
| R1 | thinking/working 用 wt 翻转闪烁，每次翻转都发全量帧（含 workTime/亮度写入），HID 流量大且可能触发固件重渲染抖动 | **闪烁改用亮度翻转**：wt=1 常亮不动，只交替发 alwaysOnBrightness=15/0（mask 0x40 单帧）。S2 真机验证亮度 0 是否等效熄灭；不行再回退 wt 翻转 |
| R2 | notification 快闪 0.4s 周期 = 每秒 5 次写入，长期审批等待时流量过高 | 快闪周期放宽到 **0.6s**（每秒 ~3.3 帧），且用 R1 的亮度翻转单帧 |
| R3 | attention（workTime=10 自动灭）10 秒后 Lite 不知情，状态表里仍是 attention，后续状态切换 diff 计算会错 | 渲染器发 attention 后起 **10s 本地定时器**，到点把该会话状态降级为 idle 并重渲染（与固件熄灭同步） |
| R4 | error 闪 3 次用全局 mode 1/0，会点亮语音键并覆盖三灯配置，结束后"回前态"需要完整重写 | 确认：error 结束必须**全量重写前态**（不是只切回 mode2）；前态在 error 触发时快照 |
| R5 | sweeping 流水 0.3s 移位太快，HID 写入可能跟不上（每帧 ACK 往返） | 流水步长放宽到 **0.5s**，每步只发变化灯的 mask 0x40 亮度帧 |
| R6 | 防抖 200ms 会吞掉 PostToolUse→PreToolUse 的快速连续 working 事件（无害），但也可能延迟 notification 首帧 | notification/error **绕过防抖立即渲染**；其余状态 200ms 防抖 |
| R7 | 设备休眠时渲染器空转写失败 | 写入失败连续 3 次 → 渲染器挂起，等设备唤醒事件（现有 wake 监听）后重放当前状态 |

## 3. 多会话仲裁

官方 hooks 带 session_id；Lite 内维护 `[sessionID: (state, lastSeen)]`：
- 优先级：notification > error > sweeping > thinking > working > attention > idle/sleeping
- 渲染最高优先会话的状态；会话 120s 无事件视为过期剔除（对齐官方 stale 清理）
- 同优先级多会话：任一 notification 即快闪（不区分哪个会话，v1 不做逐会话灯位分配）

## 4. Agent 集成清单与 App 内一键安装（2026-11-20 新增）

### 4.1 支持的 Agent（v1 目标 6 个）

调研结论：**Claude Code / Qwen Code / Qoder / CodeBuddy 四家 hooks 契约完全同构**
（settings.json + hooks 分组 + stdin JSON + session_id/hook_event_name），一套安装器通吃。
Codex 走 config.toml（官方 ustudio-cli 已有先例）。DSH 走 cordis.patch.yml 插件配置。

| Agent | 配置文件 | 契约 | 事件映射来源 | 本机状态 |
| --- | --- | --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | Claude hooks JSON（command） | 官方 mappings.js `claude-code` | 未装（目录无） |
| Qwen Code（千问 CLI） | `~/.qwen/settings.json` | Claude 同构（官方文档确认字段兼容，23 事件） | 复用 claude-code 表 | 未装 |
| Qoder（阿里） | `~/.qoder/settings.json` | Claude 同构（官方 docs.qoder.com，27 事件含 TaskCompleted/PermissionRequest） | 复用 claude-code 表 + TaskCompleted→attention | **已装**（~/.qoder 存在） |
| CodeBuddy（腾讯） | `~/.codebuddy/settings.json`（待核实路径） | Claude 同构 | 官方 mappings.js `codebuddy` | WorkBuddy 在用 |
| Codex | `~/.codex/config.toml` | TOML notify/hooks | 官方 mappings.js `codex` + installers/codex-config.js | 未装 |
| DeepSeek Harness (DSH) | `~/.dsh/profiles/<p>/cordis.patch.yml` | dsh-hooks 插件：`on: turn/end / tool/call / approval/asked`，`run:` 命令，stdin context JSON | turn/end(completed)→attention、tool/call→working、approval/asked→notification、agent/error→error | 未装 |
| **千问办公 QwenWork**（阿里，桌面端） | **企业管理后台**（安全管控→Hooks 规则），非本地文件 | **仅 HTTP hook**（type 固定 http，其他类型客户端拒收）；企业旗舰版 qwenwork_premium 12 事件；请求体与 Claude 同构（session_id/hook_event_name） | 复用 claude-code 表（事件名一致） | 未检测到 |

**QwenWork 特殊接入（官网核实 2026-11-20；已实现 2026-11-21，commits 8199174 / 8ab9239）**：它不能写本地配置、不能执行本地命令，只能 POST 到 HTTP 地址。方案：
- Lite 内起 **loopback HTTP 监听**（127.0.0.1:27950 `/qwenwork`，仅回环、随机 bearer token），收到事件 POST → 复用同一状态映射 → 渲染灯效 → 立即返回 `{}`（不干预企业流程）。**已实现**：Core 纯逻辑 `VibeKeyQwenWorkHookHandler`（token 校验 401/路由 404/405/坏 JSON 与未知事件容错/仲裁组合，19 测）+ App 壳 `QwenWorkHookListener`（NWListener 仅 loopback、HTTP 帧解析、随机高端口集成测试 5 条）
- App 内「安装」按钮 = 启动监听 + 生成各事件的 Hook 组 JSON（url 指向本机监听、带 Authorization 头）+ **一键复制** + 引导文案"到企业管理后台 安全管控→Hooks 规则 粘贴"；「卸载」= 停止监听 + 提示到后台清空配置。**监听默认不启动**，点安装才起；App 退出自动停
- 个人版无 hooks 能力 → 明确提示"千问办公 hooks 仅企业旗舰版支持"（Core 常量，安装引导内展示）
- 官方文档明示 127.0.0.1 指客户端本机——单机自用场景正好成立

预留（官方 mappings.js 已有表，安装器后续按同构扩展）：gemini-cli、cursor-agent、kiro-cli、kimi-cli、copilot-cli。

### 4.2 App 内一键安装 UX（2026-11-20 用户确认版）

Settings 面板「Agent 灯效接入」按钮 → 弹出菜单/列表窗口：
- 列表每行一个 Agent：名称 + **安装检测状态**（`已安装` / `未检测到该软件`）+ 接入状态（`已接入✓` / 未接入）+ 操作按钮 **安装 / 卸载**（按当前状态只显示其一）
- **安装前置检测（硬门槛）**：点「安装」先检测目标软件是否存在（配置目录 / App bundle / PATH 可执行文件三选一命中）。**未检测到 → 弹窗提示"请先安装 <Agent 名>，再回来接入灯效"，不写任何文件**，附官网下载链接按钮
- 检测通过 → 备份原配置（`settings.json.bak-vibekey-<ts>`）→ 合并写入（只增不删，保留已有 hooks）→ 读回校验 → 列表刷新为「已接入✓」
- 「卸载」→ 只移除 `name: "vibekey-lite"` 标记条目，其余原样保留 → 列表刷新
- QwenWork 行走特殊流程（见 4.1）：安装=起本机监听+复制配置+后台粘贴引导；卸载=停监听+后台清空引导
- 安装/卸载结果弹窗提示成功或失败原因（沿用现有 notice 弹窗模式）
- 检测规则表（Core 内纯函数，可单测）：Claude Code=`~/.claude` 或 `claude` in PATH；Qwen Code=`~/.qwen` 或 `qwen`；Qoder=`~/.qoder` 或 Qoder.app；CodeBuddy=`~/.codebuddy` 或 App；Codex=`~/.codex` 或 `codex`；DSH=`~/.dsh` 或 `dsh`；QwenWork=QwenWork.app bundle

### 4.3 安装器实现要点

- 所有写入条目带 `"name": "vibekey-lite"` 标记，幂等：重复安装先删旧标记条目再写新
- hook 命令统一：`<App内vibekeyctl路径> hook --agent <id> --event <EventName>`，timeout 5s，失败不阻塞 Agent（stdout `{}`）
- Claude 系只挂 8 个核心事件：SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/Stop/Notification/PermissionRequest/SessionEnd（+Failure 系）
- DSH 安装 = 往 cordis.patch.yml 追加 dsh-hooks 条目（YAML 合并，备份同上）；DSH 事件名不同，hook 子命令加 `--dialect dsh` 做映射
- 安装器逻辑放 VibeKeyLiteCore（纯函数：读原文→合并→产出新文），单测覆盖"保留已有 hooks/幂等/卸载干净"

## 5. 进程与 IPC

- **vibekeyctl**：Package.swift 新增 executable target（复用 VibeKeyLiteCore 编解码）。
  - `vibekeyctl led --state <s>`：手动设状态（测试/演示/脚本）
  - `vibekeyctl hook --agent <id> --event <name> [--dialect dsh]`：读 stdin JSON，映射后投递
  - `vibekeyctl install-hooks --agent <id>` / `uninstall-hooks --agent <id>`：CLI 版安装器（App 按钮调同一套 Core 逻辑）
  - `vibekeyctl led --off` / `--restore`：停用/恢复基线
- **IPC**：Unix domain socket `~/Library/Application Support/VibeKey Lite/ctl.sock`，JSON 单行 `{state, session, agent, ts}`。Lite 是唯一 HID 写入者（避免抢设备）；socket 不存在时 CLI 明确报错"Lite 未运行"，退出码非 0 但 hooks 场景 stdout 仍输出 `{}` 不阻塞 Agent。
- **Lite 内新增**：`LedStateAggregator`（仲裁）→ `LedRenderer`（定时器/防抖 200ms）→ `IOKitHardwareListener` 扩展 LED 写入方法（全量帧构造放 VibeKeyLiteCore，纯函数可单测）。
- 心跳复用现有 0.8s heartbeatTimer；LED 写入与心跳同队列串行。
- Studio 在跑时灯效挂起（沿用现有 vendor guard）；Studio 退出后自动恢复当前状态。

## 6. 安全与恢复

- 所有 LED SET 走「值域校验（mode≤2, wt≤1, bright≤20, workTime∈{10,255}）→ 全量帧 → ACK 校验」；启动时 GET 快照，`--restore` 与 App 退出时恢复基线（wt 2/0/0/1, time10, bl2, bb/ab7, mode2）。
- 渲染器崩溃/设备断开：停止定时器，重连后重放当前状态（新写入触发渲染）。
- 不碰 idx0、不碰 mic enable/flick/LedEffect 三条死路（protocol.md 已留档）。

## 7. 实施切片（每片独立可验收）

| 片 | 内容 | 验收 |
| --- | --- | --- |
| S1 | Core 全量帧构造器 + 单测；Listener LED 写入通路 | 单测过；`led --state working` 旋钮亮 |
| S2 | 渲染器（亮度翻转闪烁/流水/闪3次/attention 10s 降级）+ 状态表 | 手动逐状态切换，真机看灯 |
| S3 | socket + vibekeyctl CLI + 安装器 Core（Claude 系合并/幂等/卸载）+ 单测 | Qoder 跑一轮任务灯随事件变（本机已装） |
| S4 | Settings「Agent 灯效接入」UI：6 Agent 列表 + 一键安装/卸载 | 点按钮装 Qoder/Claude，读回校验过 |
| S5 | DSH dialect + Codex TOML 安装器 + 多会话仲裁 + Studio 共存 | 双会话并发审批优先；DSH 装后事件到灯 |

### 7.1 渲染核心纯逻辑化（2026-11-21，commit b3b1784 / 527b14f）

S2 的 App 侧 `LedRenderer`（Timer/DispatchQueue 驱动）之外，新增 **`VibeKeyLedRenderEngine`（Core 纯结构体）**：无定时器、无 HID，宿主以单调时钟 `now` 驱动 `request/tick/writeCompleted/resume`，引擎输出 `WritePlan`（desired/expected/force）。R1–R7 全部规则在注入时钟下可单测（24 条），含设计稿未覆盖的边界：

- **error 期间来新事件**：非 error 事件立即抢占闪烁序列，前态快照丢弃（不延迟恢复）
- **写失败重试不被去重吞掉**：`lastRenderedState`（去重标记）与 `currentState`（对外报告）分离，失败回滚前者
- **WritePlan.force**：状态入场/动画步的写入即使与上次确认表相同也不得被宿主丢弃（固件需要"新写入"触发渲染）

仲裁器补 6 条边界测试（120s 恰好过期、同会话覆盖、优先级链、resolve 只读）。**硬件接线待 thinking 灯观察结论后进行**：届时 App 侧 LedRenderer 改为薄壳驱动 Engine，Timer 只负责按时调 tick。

## 8. 用户配合

- S2/S3 验收需真机看灯（每轮约 2 分钟，沿用"一次一状态、保持住等确认"节奏）
- 一键安装会改各 Agent 的 settings.json（先备份、只增不删、带标记可卸载），App 内点按钮即视为授权
- Qoder 本机已装，S3 用它做首个端到端验收；DSH/Codex 本机未装，安装器先做"预写配置"路径