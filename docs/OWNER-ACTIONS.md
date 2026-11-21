# 佐井决策/操作清单（OWNER-ACTIONS）

> 更新：2026-11-21。代码与文档已 delivered（222 测全绿、已 push origin）。
> 以下三项是**仅剩**需要你决策或操作的事项，按依赖顺序排列。每项含：为什么需要你、具体做什么、不做的后果。
> 接线细节见 docs/wiring-runbook.md；完整步骤见 docs/delivery-checklist.md。

## ① thinking 灯观察结论（技术卡点，最先做）

- **事项**：确认 thinking 状态慢闪的灯位——旋钮，还是中键+下键。
- **为什么需要你**：只有肉眼能判定。历史上两次观察矛盾（隔离测试=旋钮 ✅；六状态序列=中+下，后查明是真实 hooks 仲裁压制，非映射错误），代码按"无新证据不改已确认行为"原则保持旋钮 provisional，等你一锤定音。
- **具体做什么**（1 分钟）：
  ```sh
  "/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl" led --state thinking
  ```
  盯设备 15 秒，回复"旋钮"或"中+下"即可。（当前 hooks 已卸载，是纯净环境；若灯被快闪抢走，先跑 `vibekeyctl detect` 确认。）
- **不做的后果**：thinking 灯位永远 provisional；后续部署/hooks 装回可以照常做，但 thinking 显示可能与你的预期不符，且无法关闭这个唯一技术卡点。

## ② 部署放行：新版 App 替换安装版

- **事项**：批准把已构建验证的新版（薄壳渲染器 + QwenWork 监听 + M1 自动切组）替换 `/Applications/VibeKey Lite.app`。
- **为什么需要你**：替换会重启你正在用的常驻 App（短暂中断按键增强），属于影响运行环境的操作，按约定必须你放行。
- **具体做什么**：回复"部署放行"即可，agent 执行 runbook 第 3-4 步（打包已演练过，同证书签名保留 TCC 授权）：
  ```sh
  # agent 执行，你只需放行：
  osascript -e 'tell application "VibeKey Lite" to quit'
  ditto ".build/app/VibeKey Lite.app" "/Applications/VibeKey Lite.app"
  open "/Applications/VibeKey Lite.app"
  ```
  替换后建议跑 `./scripts/acceptance.sh live` 的 A7 段肉眼核对（2 分钟）。
- **不做的后果**：运行中的旧版没有薄壳渲染器/QwenWork 监听/M1 自动切组；GitHub 上的新代码与本机运行版本持续脱节。

## ③ hooks 装回放行：WorkBuddy 灯效端到端闭环

- **事项**：批准把 vibekey-lite hooks 装回 `~/.workbuddy/settings.json`（当前为纯净测试保持卸载）。
- **为什么需要你**：装回后你的每个 WorkBuddy 会话都会驱动设备灯，属于改变日常使用体验的操作；且此前卸载是你明确要求的测试状态。
- **具体做什么**：回复"hooks 装回"即可，agent 执行：
  ```sh
  "/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl" install-hooks --agent codebuddy
  ```
  只增不删+自动备份，你原有的 hindsight/skill-forge hooks 不受影响。装回后随便跑一轮任务看灯即验收。
- **不做的后果**：WorkBuddy 会话不驱动灯，M2 端到端价值无法在日常使用中兑现（手动 `led --state` 仍可用）。

---

## 依赖关系与建议顺序

```
① 灯观察（1 分钟）→ ② 部署放行（含 live 验收 2 分钟）→ ③ hooks 装回（10 秒）
```
三项可以一次性回复（例："旋钮；部署放行；hooks 装回"），agent 按 runbook 5 分钟走完。
②③ 不依赖 ① 也能做，但 ① 先做可让部署版直接带上正确灯位，避免二次替换。

## 已放行、无需再决策的事项（存档）
- push origin：已放行并执行（35+ commits 在 GitHub）
- 代码/测试/文档修改、本地构建：长期授权
- 红线（不变）：不碰固件/配对/重置、设备写入只限已验证命令组、不发布 release