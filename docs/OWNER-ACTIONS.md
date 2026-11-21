# 佐井决策/操作清单（OWNER-ACTIONS）

> 更新：2026-11-21 10:15。代码与文档已 delivered（222 测全绿、已 push origin）。
> ① 已完成；**仅剩 ②③ 两项**需要你放行。每项含：为什么需要你、具体做什么、不做的后果。
> 接线细节见 docs/wiring-runbook.md；完整步骤见 docs/delivery-checklist.md。

## ① thinking 灯观察结论 ✅ 已完成（2026-11-21 10:14）

- **结论**：**旋钮慢闪**（佐井纯净环境隔离观察确认："现在是旋钮了，上面那个旋钮是闪动的"）。
- **落地**：`thinkingLeds = [3]` 由 provisional 转 CONFIRMED，值无需改动；全部 provisional 标注已清除（代码注释/测试守卫/脚本/文档同步）。历史矛盾（六状态序列"中+下闪"）确认为真实 hooks 仲裁压制，映射从未错。
- 唯一技术卡点已关闭。

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
① 灯观察 ✅ 已完成 → ② 部署放行（含 live 验收 2 分钟）→ ③ hooks 装回（10 秒）
```
②③ 可以一次性回复（例："部署放行；hooks 装回"），agent 按 runbook 第 3-6 步 5 分钟走完。

## 已放行、无需再决策的事项（存档）
- push origin：已放行并执行（35+ commits 在 GitHub）
- 代码/测试/文档修改、本地构建：长期授权
- 红线（不变）：不碰固件/配对/重置、设备写入只限已验证命令组、不发布 release