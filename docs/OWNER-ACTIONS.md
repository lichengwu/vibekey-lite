# 佐井决策/操作清单（OWNER-ACTIONS）

> 更新：2026-11-21 10:22。**三项全部完成，无待决策事项。** M2 端到端已闭环（真实 WorkBuddy 会话事件驱动灯）。
> 存档如下；接线细节见 docs/wiring-runbook.md；完整步骤见 docs/delivery-checklist.md。

## ① thinking 灯观察结论 ✅ 已完成（2026-11-21 10:14）

- **结论**：**旋钮慢闪**（佐井纯净环境隔离观察确认："现在是旋钮了，上面那个旋钮是闪动的"）。
- **落地**：`thinkingLeds = [3]` 由 provisional 转 CONFIRMED，值无需改动；全部 provisional 标注已清除（代码注释/测试守卫/脚本/文档同步）。历史矛盾（六状态序列"中+下闪"）确认为真实 hooks 仲裁压制，映射从未错。

## ② 部署放行 ✅ 已完成（2026-11-21 10:21，佐井放行"把最后两步也做完"）

- 222 测绿 → 同证书签名打包 → 替换 `/Applications/VibeKey Lite.app`（TCC 授权沿用）→ socket 正常 → working/thinking/idle 冒烟全过。
- 运行版即最新代码：薄壳渲染器 + Engine 全规则 + QwenWork 监听（默认不启动）+ M1 自动切组（映射默认空）。

## ③ hooks 装回 ✅ 已完成（2026-11-21 10:22）

- `install-hooks --agent codebuddy` → 11 事件条目写入 `~/.workbuddy/settings.json`；原有 hindsight/skill-forge hooks 原样保留；备份 `settings.json.bak-vibekey-1795227746`。
- **端到端即时验证**：装回 2 秒后渲染状态=working——巡检会话自身的 PreToolUse 事件已驱动灯，全链路（hooks→CLI→socket→Engine→HID→灯）真实闭环。

---

## 后续可选（非待办，佐井自行决定）
- M1 映射表：config.json 加 `appProfileMapping`（README/user-guide 有本机实查示例），重启 App 生效
- QwenWork：需企业旗舰版环境，UI 点安装即起监听+复制配置
- 六状态完整 live 验收：`./scripts/acceptance.sh live`（A7 段肉眼核对，随时可跑）

## 已放行、无需再决策的事项（存档）
- push origin：已放行并执行（35+ commits 在 GitHub）
- 代码/测试/文档修改、本地构建：长期授权
- 红线（不变）：不碰固件/配对/重置、设备写入只限已验证命令组、不发布 release