# VibeKey Lite 用户指南（自助操作手册）

> 配套：README（功能概览）、docs/protocol.md（协议）、docs/m2-led-design.md（灯效设计）、docs/delivery-checklist.md（交付接线清单）。
> 本指南目标：不看代码也能完成安装、配置、验收、排障。

## 1. 安装与替换

### 首次安装
1. 完全退出 Ulanzi Studio（两个宿主会抢设备）。
2. 构建：`VIBEKEY_SIGNING_IDENTITY=<你的开发证书> ./build-app.sh`
   - **必须用同一张有效证书**（ad-hoc 签名会使 TCC 授权失效）。本机证书指纹见 build-app.sh 注释/交接记录。
   - 产物：`.build/app/VibeKey Lite.app`（含 `Contents/MacOS/vibekeyctl`）。
3. 复制到 `/Applications/`，启动。
4. 系统设置 → 隐私与安全性 → 允许「输入监控」和「辅助使用」。

### 替换升级（保留授权）
```sh
osascript -e 'tell application "VibeKey Lite" to quit'
ditto ".build/app/VibeKey Lite.app" "/Applications/VibeKey Lite.app"
codesign --verify --strict "/Applications/VibeKey Lite.app"
open "/Applications/VibeKey Lite.app"
```
同一证书签名 → 授权沿用，无需重新勾选。替换后 `vibekeyctl status` 应返回 `state=idle`。

## 2. config.json 全字段说明

位置：`~/Library/Application Support/VibeKey Lite/config.json`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `activeProfile` | `"a"` / `"b"` | 当前组：a=AI，b=系统 |
| `offlineProfile` | `"a"` / `"b"` / 缺省 | 已写入设备六格的离线备用组；缺省=从未写过，App 会提示先按「离线备用」 |
| `profileA` / `profileB` | 对象 | 两组按键映射，键为控制名（见下），值为动作 |
| `needsHardwareSync` | bool | 内部标记：是否需要完整六格写回；**不要手改**（旧配置的 false 若无 offlineProfile 佐证会被强制重置为 true） |
| `appProfileMapping` | 对象 | M1：bundleID → `"a"`/`"b"`；缺省/空=功能关闭 |

控制名：`knobPress`（旋钮单按）、`knobDoublePress`（双按）、`knobLeft`/`knobRight`（左右旋）、`topButton`/`middleButton`/`bottomButton`（上/中/下键）。

动作值两种形态：
- 预设字符串：`"selectAll"`、`"returnKey"`、`"volumeUp"` 等（完整列表见 Models.swift `KeyAction`，UI 下拉即全集）
- 组合键对象：`{"type":"shortcut","shortcut":{...}}`——**建议用 UI 录制器生成**，手写易错（最多 4 键，区分左右修饰键）

注意：`fnDoubleTap`、`voiceInput` 是 App-only 动作，写离线六格时对应格为空（固件存不了）。

### appProfileMapping 推荐表（本机 mdls 实查，2026-11-21）

判断标准：AI 对话/编程类 → `"a"`；其余不映射（保持当前组）。

```json
{
  "appProfileMapping": {
    "com.tencent.workbuddy.mac": "a",
    "com.apple.Terminal": "a",
    "com.apple.dt.Xcode": "a",
    "com.qoder.QoderWake.MenuBar": "a"
  }
}
```

**QoderWake 注意事项**：`com.qoder.QoderWake.MenuBar` 是菜单栏辅助 App，**不是 Qoder 主编辑器**。日常用主编辑器的话先查它的真实 bundleID：
```sh
mdls -name kMDItemCFBundleIdentifier -raw /Applications/Qoder.app
# 或
osascript -e 'id of app "Qoder"'
```
VS Code/Cursor/Claude/ChatGPT 桌面端本机未装，装后同法查 ID 加入。改完 config 重启 App 生效；启动时会读一次前台 App，切换有 200ms 防抖。

## 3. Agent 灯效（M2）

### 状态灯语义
| 状态 | 灯效 | 含义 |
| --- | --- | --- |
| idle/sleeping | 全灭 | 空闲 |
| thinking | 慢闪 1.2s（灯位 provisional=旋钮，待观察结论） | 思考中 |
| working | 旋钮常亮 | 干活中 |
| attention | 中键亮 10s 自动灭 | 回合完成 |
| notification | 中+下快闪 0.6s | **需要你审批**（最高优先） |
| error | 全灯闪 3 次→恢复前态 | 出错 |
| sweeping | 三灯流水 0.5s | 压缩上下文 |

语音键灯不参与（固件按键反馈，按下松开闪一下属正常）。

### hooks 安装/卸载
**UI 方式**：菜单栏 → 设置 →「Agent 灯效接入…」→ 列表选 Agent → 安装/卸载。
- 安装前自动检测软件是否存在；未装会提示先装，**绝不写配置**
- 安装=备份原配置（`.bak-vibekey-<时间戳>`）→ 只新增带 `vibekey-lite` 标记的条目 → 读回校验
- 卸载=只删标记条目，你已有的 hooks 原样保留

**CLI 方式**：
```sh
CTL="/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl"
"$CTL" detect                          # 各 Agent 安装/接入状态
"$CTL" install-hooks --agent qoder     # claude-code|qwen-code|qoder|codebuddy|codex|dsh
"$CTL" uninstall-hooks --agent qoder
"$CTL" led --state working             # 手动设状态（测试）
"$CTL" led --restore                   # 恢复出厂灯效基线
"$CTL" status                          # 当前渲染状态
```
- codebuddy 目标实际写 `~/.workbuddy/settings.json`（WorkBuddy 真实路径）
- codex 额外在 config.toml 开 `[features] hooks=true`，**需在 Codex 内 `/hooks` 批准后才生效**
- dsh 写 `~/.dsh/profiles/web/cordis.patch.yml` 标记块，重启 dsh 生效
- hook 模式恒输出 `{}` 退出 0，永不阻塞 Agent

### QwenWork（千问办公，企业旗舰版专属）
个人版无 hooks 能力。企业版流程：UI 点安装 → 本机监听启动（127.0.0.1:27950，仅回环）→ 复制 7 事件配置 → 企业管理后台（组织与安全→安全管控→Hooks 规则）逐事件粘贴 → 跑任务看灯。卸载=停监听+后台清空规则。监听默认不启动，App 退出自动停。

### 多会话仲裁（重要：不是 bug）
多个 Agent 会话同时跑时，灯只显示**最高优先级**状态：需审批 > 出错 > 压缩 > 思考 > 干活 > 完成 > 空闲。120 秒无事件的会话自动剔除。

**已查明的行为**：真实 WorkBuddy 会话在跑工具时会持续发 Notification 等事件。若你同时手动 `led --state thinking` 测试，会看到灯被"中+下快闪"压住——**这是仲裁正确工作，不是渲染 bug**。纯净测试请先卸载 hooks（`uninstall-hooks --agent codebuddy`），测完再装回。

## 4. 验收脚本

```sh
./scripts/acceptance.sh offline   # 离线：全部自动断言（mock 设备，不碰硬件）
./scripts/acceptance.sh live      # 真机：自动断言 + 逐状态保持 + 人工项暂停
```
live 模式 4 个「佐井操作」项：A7 六状态肉眼核对、B4 QwenWork 全流程、C3 M1 按键回归、D2 收尾。每项可输入 `s` 跳过，绝不自动通过。

## 5. 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| `vibekeyctl` 报"VibeKey Lite 未运行" | App 没启动或 socket 未就绪；启动 App 等 3 秒重试 |
| 灯完全不动 | ① Ulanzi Studio 在跑（灯效自动挂起，退出 Studio 即恢复）② 设备休眠（按任意键唤醒，10s 内自动重放）③ 连续写失败 3 次挂起（同②自愈） |
| 手动设的状态被"抢走" | 真实 hooks 仲裁压制（见 §3），非 bug；纯净测试先卸 hooks |
| thinking 闪的灯位和预期不符 | 灯位 provisional，以隔离观察结论为准；接线点唯一：`VibeKeyLedRenderEngine.thinkingLeds` |
| 灯亮约 10 秒自己灭 | attention 状态的预期行为（完成铃）；若是 working 也这样，检查是否被 attention 事件覆盖 |
| 语音键灯自己闪 | 固件按键反馈（按下→松开闪一下），正常，主机不可控 |
| 授权反复失效 | 用了 ad-hoc 签名；必须同一张开发证书重签 |
| hooks 装了没反应 | codex 需 `/hooks` 批准；dsh 需重启；其余需新会话（配置在会话启动时加载） |
| 设备按键失灵 | App 意外退出后固件超时回原生（曾实测成功）；重启 App 即恢复在线模式 |

## 6. 红线（任何操作都适用）
- 不碰固件升级/配对/重置；设备写入只限 0x0B 灯控组与已验证的六格写入
- 测试收尾恢复基线：`vibekeyctl led --restore`
- Studio 与 Lite 不同时跑