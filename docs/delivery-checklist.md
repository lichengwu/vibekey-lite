# 交付接线 Checklist（①② 已完成，剩部署+hooks）

> 前提：代码与文档已达交付标准（222 测全绿）。① 灯观察 ✅（2026-11-21 确认=旋钮）；仅剩 部署放行 + hooks 装回。
> 每步标注执行者：🤖=agent 可自动 / 👤=需佐井放行或操作。

## 步骤 0：灯观察结论 ✅ 已完成（2026-11-21 10:14）
- 佐井纯净环境隔离观察确认：**旋钮慢闪**。`thinkingLeds=[3]` CONFIRMED，provisional 全清。

## 步骤 1：改唯一接线点 ✅ 无需改动
```swift
// Sources/VibeKeyLiteCore/VibeKeyLedRenderEngine.swift
public static let thinkingLeds: [Int] = [3]      // 旋钮确认 → 保持（已确认）
```
值正确无需改；注释/守卫已由 provisional 转 confirmed。其余结构零改动。

## 步骤 2：测试 🤖
```sh
swift test --disable-sandbox    # 必须全绿才继续
```
若改了 [1,2]：`testThinkingDefaultIsKnobProvisional` 断言需同步更新为新的确认值（该测试就是接线点的守卫）。

## 步骤 3：打包 🤖（构建无需放行）
```sh
VIBEKEY_SIGNING_IDENTITY=F7FBEA12E4E4DB3128C39311E8AF83984FD86460 ./build-app.sh
codesign --verify --strict ".build/app/VibeKey Lite.app"
```

## 步骤 4：替换安装版 👤 放行后 🤖 执行
```sh
osascript -e 'tell application "VibeKey Lite" to quit'
ditto ".build/app/VibeKey Lite.app" "/Applications/VibeKey Lite.app"
open "/Applications/VibeKey Lite.app"
"/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl" status   # 应 state=idle
```

## 步骤 5：live 验收 👤 操作 + 🤖 驱动
```sh
./scripts/acceptance.sh live
```
- A7：六状态逐段核对（thinking 按新结论）
- B4：QwenWork 安装→后台粘贴→事件到灯→卸载（无企业版可跳过）
- C3：M1 配映射后按键回归（未配可跳过）
- D2：收尾基线确认

## 步骤 6：装回 WorkBuddy hooks 👤 放行后 🤖 执行
```sh
"/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl" install-hooks --agent codebuddy
```
装回后真实会话事件到灯即端到端闭环。原有 hindsight hooks 不受影响（只增不删+备份）。

## 步骤 7：commit 🤖
按功能拆本地 commit（英文 message）。**不 push**（公共远端推送需佐井另行放行）。

---

## 当前积压盘点（2026-11-21 审计）

| 项 | 分类 | 状态 |
| --- | --- | --- |
| ~~`thinkingLeds` provisional 标注~~ | 等灯结论 | ✅ 已确认=旋钮（2026-11-21），标注全清 |
| 新版 App 替换安装版 | 等部署放行 | 产物已构建验证 |
| WorkBuddy hooks 装回 | 等部署放行 | 卸载状态保持中 |
| ~~"S5 后续版本提供"过时文案~~ | 现在能清 | ✅ 已清（5b66e51） |
| ~~CodeBuddy 路径"待核实"~~ | 现在能清 | ✅ 已清（5b66e51，实为 ~/.workbuddy） |
| 无其他 TODO/FIXME/无主积压 | — | 全仓 grep 确认 |