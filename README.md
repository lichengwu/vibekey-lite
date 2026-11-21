# VibeKey Lite

繁體中文｜[English](#english)

VibeKey Lite 是 AU05／VibeKey 的輕量 macOS 選單列設定工具。它提供兩組完整六鍵設定，不需要 Ulanzi Studio、帳號或網路。

## 主要功能

- AI、系統兩組設定；每組六個原生單按動作都可自訂。
- 旋鈕單按保留原設定；雙按可另行設定（預設切組）；按住約 0.65 秒固定切組。
- 可錄製實體鍵盤按鍵或最多四鍵的組合鍵。
- 可分辨左／右 Option、Control、Shift、Command，並內建 F1–F12、Delete、Forward Delete、方向鍵、剪貼簿及媒體控制。
- 介面直接顯示 AU05 電量、充電狀態、待機時間與自動關機時間；這些資料只讀取，不會擅自改寫。
- 按「設為離線備用」會把目前完整六格寫進 AU05；App 正常結束後使用那一組。
- 不包含或載入 Ulanzi 的程式庫，也不會連線到雲端。

AU05 本身只有一組六格儲存空間。VibeKey Lite 保存兩組；日常切組只切 App 內的設定，不會反覆寫入裝置。只有明確按「設為離線備用」才會更新硬體內的六格。

## 單按、雙按與長按

AU05 韌體只會離線保存單按。為了同時分辨三種手勢，VibeKey Lite 執行時會啟用裝置的線上事件模式，接收六個實體控制的事件，再送出目前設定。

- 單按會等待約 0.28 秒，確認不是雙按後才執行。
- 雙按使用「旋鈕雙按」那一格；預設是切換 AI／系統。
- 長按達 0.65 秒後，放開時切換 AI／系統。
- 正常結束、Mac 睡眠、Ulanzi Studio 開啟或線上傳輸失敗時，App 會明確退出線上模式，讓 AU05 回到原生六鍵。
- Mac 關機前會強制交還原生模式；下次啟動會先清除可能殘留的線上狀態，再重新連線。若開機時 USB 尚未就緒，會自動重試三次；全程不會重寫六鍵設定。
- 裝置閒置達它保存的待機時間後，App 會停止線上心跳並交還原生模式，讓 AU05 自行待機與關機。
- 控制器從待機或自動關機醒來時，App 會依裝置通知自動恢復單按、雙按與長按；若舊 USB 連線已失效，會自動重建三次。若韌體沒有送出通知，第一下原生單按仍可觸發備援恢復。
- 待機前後打開選單列設定只會查看狀態，不會喚醒 AU05，也不會重算閒置時間。
- App 意外終止後的韌體逾時回復曾實際觀察成功；精確回復時間仍需依裝置韌體驗證。

線上手勢需要 macOS 的「輸入監控」與「輔助使用」權限。權限不完整時不會啟用線上模式，AU05 仍直接執行原生六鍵。

## Fn 限制

Fn 不是一般 USB HID 按鍵，AU05 韌體無法把它保存成離線快捷鍵。VibeKey Lite 開啟時，任何控制都可選「Fn 按兩次」，由 App 送出兩次 Fn；裝置內原有的離線按鍵不會被改寫。錄製器遇到實體 Fn 仍會明確拒絕，不會偷換成別的按鍵；實機不會輸出的 `F19`、`F20` 也會被拒絕。

## 使用方式

1. 完全結束 Ulanzi Studio。
2. 開啟 VibeKey Lite。
3. 在「系統設定 → 隱私權與安全性」允許 VibeKey Lite 的「輸入監控」與「輔助使用」。
4. 從選單列的小控制器圖示打開介面，設定兩組動作。

若要立即停用多重手勢，按「只用原生」；AU05 會回到硬體裡的離線備用六鍵。

設定檔位於：

```text
~/Library/Application Support/VibeKey Lite/config.json
```

## 按前台 App 自動切組（M1）

在 config.json 加入 `appProfileMapping`（bundleID → `"a"`=AI／`"b"`=系統），前台 App 命中映射且與目前組別不同時自動切換；未命中的 App 保持目前組別，不會來回跳。預設為空（功能關閉）。

判斷標準：**AI 對話／編程類 App → AI 組（"a"）；其餘不映射**（保持當前組，日常 App 自然落在系統組）。以下為本機實測 bundleID 的推薦示例（2026-11-21，mdls 查證）：

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

> 注意：`com.qoder.QoderWake.MenuBar` 是 QoderWake 選單列輔助 App；若你日常用的是 Qoder 主編輯器，請用下方命令查它的實際 bundleID 再映射。VS Code／Cursor／Claude／ChatGPT 桌面端本機未安裝，裝好後同样查 ID 加入即可。

- 啟動時會讀一次前台 App；App 切換有 200ms 防抖，⌘Tab 風暴不會連環切。
- 自動切組只切 App 內設定，不寫裝置六格；「離線備用」不受影響。
- bundleID 查詢：`mdls -name kMDItemCFBundleIdentifier -raw /Applications/某App.app` 或 `osascript -e 'id of app "Safari"'`。

## Agent 狀態燈效（M2）

AU05 的三顆燈（中鍵、下鍵、旋鈕）可顯示 coding Agent 的工作狀態；語音鍵燈由韌體自驅（按鍵回饋），不參與。

| 狀態 | 燈效 |
| --- | --- |
| idle／sleeping | 全滅 |
| thinking | 旋鈕慢閃（1.2s） |
| working | 旋鈕常亮 |
| attention（回合完成） | 中鍵亮 10 秒自動滅 |
| notification（需審批） | 中＋下快閃（0.6s），最高優先 |
| error | 全燈全亮閃 3 次後恢復前態 |
| sweeping（壓縮上下文） | 三燈流水（0.5s） |

### vibekeyctl 命令列

```sh
CTL="/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl"
"$CTL" led --state working        # 手動設狀態（測試／腳本）
"$CTL" led --restore              # 恢復出廠燈效基線
"$CTL" status                     # 查詢目前狀態
"$CTL" detect                     # 列出各 Agent 安裝／接入狀態
"$CTL" install-hooks --agent qoder
"$CTL" uninstall-hooks --agent qoder
```

### 一鍵接入 Agent

選單列設定 →「Agent 燈效接入…」：列表顯示每個 Agent 的檢測狀態，點「安裝」自動備份原配置、只新增帶 `vibekey-lite` 標記的 hooks（你已有的 hooks 原樣保留），點「卸載」只移除標記條目。**未檢測到軟體會提示先安裝，不會寫任何配置。**

支援：Claude Code、Qwen Code、Qoder、CodeBuddy/WorkBuddy（同構 JSON 安裝器）；Codex（hooks.json＋config.toml features 開關，需在 Codex 內 `/hooks` 批准）；DeepSeek Harness（cordis.patch.yml）；千問辦公 QwenWork（企業旗艦版，HTTP hooks，App 內複製配置到企業後台粘貼）。

### 多會話仲裁

多個 Agent 會話同時跑時，按優先級顯示最高狀態：需審批 > 出錯 > 壓縮 > 思考 > 幹活 > 完成 > 空閒。120 秒無事件的會話自動剔除。Ulanzi Studio 開啟時燈效掛起，退出後自動恢復。

> 實作狀態（2026-11-21）：渲染核心規則（R1–R7：亮度翻轉閃爍、attention 10s 降級、error 快照恢復、防抖豁免、寫失敗掛起重放、多會話仲裁）已抽為 Core 純邏輯 `VibeKeyLedRenderEngine`，注入時鐘單測全綠；硬體渲染接線待燈效觀察確認後完成。

燈效協議細節見 [docs/protocol.md](docs/protocol.md)，設計見 [docs/m2-led-design.md](docs/m2-led-design.md)。

## 建置

需求：Apple Silicon Mac、macOS 13 或更新版本、Xcode Command Line Tools。

```sh
swift test
./build-app.sh
open '.build/app/VibeKey Lite.app'
```

每次使用同一張有效簽章，macOS 才能沿用權限：

```sh
VIBEKEY_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./build-app.sh
```

成品位於 `.build/app/VibeKey Lite.app`；建置不會自動安裝。

## 實作與安全

程式只配對 AU05 的 `VID 0xFFF1`、`PID 0x00DD`。原生設定與線上事件都走 custom usage page `0xFFFC`、usage `1`、report ID `0x55` 的 64-byte TEA 加密 report。

寫入前會先驗證完整六格。不支援的動作不會造成只寫一半；若裝置在實際 I/O 中途拔除，仍可能留下混合設定，此時重新寫入目前設定即可。

這是獨立製作的非官方相容實作，與 Ulanzi 無關。專案不包含、不複製、不載入，也不連結 Ulanzi Studio 的 `kwdm.dylib` 或其他專有檔案。

專案使用 [MIT License](LICENSE)。協定研究見 [docs/protocol.md](docs/protocol.md)。

**自助操作手冊**：[docs/user-guide.md](docs/user-guide.md)（安裝替換、config.json 全字段、映射表、驗收腳本、hooks 流程、故障排查）。
**交付接線清單**：[docs/delivery-checklist.md](docs/delivery-checklist.md)（燈觀察結論回來後照著跑，每步標注放行點）。
**接線 Runbook**：[docs/wiring-runbook.md](docs/wiring-runbook.md)（兩種燈觀察結論分支均已預寫測試並演練，5 分鐘走完）。
**佐井決策清單**：[docs/OWNER-ACTIONS.md](docs/OWNER-ACTIONS.md)（僅剩三項：燈觀察／部署放行／hooks 裝回）。

---

## English

VibeKey Lite is a lightweight macOS menu bar configurator for the AU05/VibeKey. It provides two complete six-control profiles without Ulanzi Studio, an account, or a network connection.

### Features

- Two profiles with all six native single-press actions configurable.
- Encoder single press keeps its configured action; double press has a separate configurable action (profile switching by default); a 0.65-second hold switches profiles.
- Record a physical key or a chord of up to four keys.
- Left/right Option, Control, Shift, and Command remain distinct. F1–F12, Delete, Forward Delete, navigation, editing, and supported media actions are included.
- The UI shows battery, charging state, standby time, and automatic power-off time using read-only device queries.
- **Set as Offline Backup** writes the current six single-press mappings to the AU05. After a normal app exit, the device uses that profile.
- No vendor library, account, cloud connection, or third-party dependency.

The AU05 stores one six-slot profile. VibeKey Lite keeps two profiles; normal profile switching only changes the host-side selection and does not repeatedly write device flash. Hardware changes occur only when **Set as Offline Backup** is explicitly used.

### Single, double, and hold

The AU05 firmware stores only single-press actions offline. While VibeKey Lite runs, it enables the device's online event mode, receives all six physical controls, and emits the configured actions so it can distinguish all three gestures.

- A single press waits about 0.28 seconds to rule out a double press.
- A double press uses its own configurable row and switches profiles by default.
- A 0.65-second hold switches profiles when released.
- Normal quit, Mac sleep, vendor-app launch, or transport failure explicitly leaves online mode and restores native operation.
- Before Mac shutdown the app forces native mode; the next launch clears any stale online state before reconnecting. If USB is not ready yet, it retries three times without rewriting the six stored shortcuts.
- When the saved device standby delay elapses without AU05 input, the app stops host-online traffic and hands control back to native mode so firmware standby and power-off can run.
- When the controller wakes from standby or automatic power-off, its device notice restores single-, double-, and long-press gestures automatically. A stale USB session is rebuilt up to three times. A first native press remains the fallback when firmware emits no wake notice.
- Opening the menu bar settings only shows status; it neither wakes the AU05 nor restarts the inactivity timer.
- Firmware timeout recovery after an unexpected app stop has been observed once; exact recovery timing still depends on controlled device testing.

Online gestures require both Input Monitoring and Accessibility permission. If either permission is unavailable, online mode is not enabled and the AU05 continues using its six native actions.

### Fn limitation

Fn is not a normal USB HID key and cannot be stored as an offline AU05 shortcut. While VibeKey Lite is running, any control can select **Fn Double Tap**; the app sends two Fn taps without rewriting the device's existing offline keys. The recorder still rejects a physical Fn input instead of substituting another key. It also rejects `F19` and `F20`, which the tested AU05 did not emit.

### Usage

1. Quit Ulanzi Studio completely.
2. Open VibeKey Lite.
3. Allow both Input Monitoring and Accessibility under System Settings → Privacy & Security.
4. Open the small controller icon in the menu bar and configure both profiles.

Use **Native Only** for an immediate exit from enhanced gesture mode; the AU05 returns to its stored six-key offline backup.

Configuration is stored at:

```text
~/Library/Application Support/VibeKey Lite/config.json
```

### Auto profile switching by frontmost app (M1)

Add `appProfileMapping` (bundleID → `"a"`=AI / `"b"`=System) to config.json. When the frontmost app matches a mapping and differs from the active profile, the app switches automatically; unmapped apps keep the current profile. Default is empty (feature off).

Rule of thumb: **AI chat / coding apps → AI profile ("a"); leave everything else unmapped**. Recommended example with bundleIDs verified on this machine (2026-11-21, via mdls):

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

> Note: `com.qoder.QoderWake.MenuBar` is the QoderWake menu-bar helper; if you use the main Qoder editor, look up its real bundleID first. VS Code / Cursor / Claude / ChatGPT desktop apps are not installed here — add them the same way once installed.

The frontmost app is read once at launch; activation events are debounced by 200 ms. Auto-switching only changes the host-side selection and never writes the device's six slots. Find a bundleID with `mdls -name kMDItemCFBundleIdentifier -raw /Applications/SomeApp.app` or `osascript -e 'id of app "Safari"'`.

### Agent status lights (M2)

Three AU05 LEDs (middle key, bottom key, knob) show coding-agent state; the voice-key LED is firmware-driven key feedback and does not participate.

| State | Light pattern |
| --- | --- |
| idle / sleeping | all off |
| thinking | knob slow blink (1.2 s) |
| working | knob solid |
| attention (turn done) | middle key lit 10 s, auto-off |
| notification (approval needed) | middle + bottom fast blink (0.6 s), highest priority |
| error | all LEDs flash 3×, then restore previous state |
| sweeping (compaction) | three-LED chase (0.5 s) |

CLI: `vibekeyctl led --state <state> | --restore`, `status`, `detect`, `install-hooks --agent <id>`, `uninstall-hooks --agent <id>` (binary inside the app bundle at `Contents/MacOS/vibekeyctl`).

One-click agent onboarding: menu bar settings → "Agent 灯效接入…" lists each agent with detection status; Install backs up the existing config and additively merges hooks tagged `vibekey-lite`; Uninstall removes only tagged entries. Absent software is never configured — you are prompted to install it first. Supported: Claude Code, Qwen Code, Qoder, CodeBuddy/WorkBuddy (shared JSON installer); Codex (hooks.json + config.toml feature flag, approve via `/hooks`); DeepSeek Harness (cordis.patch.yml); QwenWork (enterprise edition, HTTP hooks via console paste guide).

Multi-session arbitration shows the highest-priority state (approval > error > compaction > thinking > working > done > idle); sessions silent for 120 s are dropped. Lights suspend while Ulanzi Studio runs and resume when it exits.

> Implementation status (2026-11-21): the rendering rules (R1–R7: brightness-toggle blinking, attention 10 s downgrade, error snapshot restore, debounce bypass, write-failure suspend/replay, multi-session arbitration) are implemented as pure Core logic in `VibeKeyLedRenderEngine` with injected-clock tests, all green; hardware wiring follows after the pending LED observation.

See [docs/protocol.md](docs/protocol.md) and [docs/m2-led-design.md](docs/m2-led-design.md).

### Build

Requires Apple Silicon, macOS 13 or newer, and Xcode Command Line Tools.

```sh
swift test
./build-app.sh
open '.build/app/VibeKey Lite.app'
```

Use the same valid signing identity for every build so macOS can preserve permissions:

```sh
VIBEKEY_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./build-app.sh
```

The bundle is written to `.build/app/VibeKey Lite.app`; the build does not install it.

### Implementation and safety

The app only matches AU05 `VID 0xFFF1`, `PID 0x00DD`. Native settings and online events use custom usage page `0xFFFC`, usage `1`, report ID `0x55`, with encrypted 64-byte reports.

All six mappings are validated before a write begins. A physical disconnect during I/O can still leave a mixed profile; reconnect and rewrite the active profile if that happens.

This is an independent, unofficial compatibility implementation. It does not contain, copy, load, or link against Ulanzi Studio's `kwdm.dylib` or other proprietary files.

Licensed under the [MIT License](LICENSE). See [docs/protocol.md](docs/protocol.md) for protocol notes.

**Self-service manual**: [docs/user-guide.md](docs/user-guide.md) (install/replace, full config.json reference, mapping table, acceptance script, hooks flow, troubleshooting).
**Delivery checklist**: [docs/delivery-checklist.md](docs/delivery-checklist.md) (run after the LED observation lands; each step marks who must approve).
**Wiring runbook**: [docs/wiring-runbook.md](docs/wiring-runbook.md) (both observation-outcome branches pre-tested and rehearsed; 5-minute walkthrough).
**Owner actions**: [docs/OWNER-ACTIONS.md](docs/OWNER-ACTIONS.md) (three remaining decisions: LED observation / deploy approval / hooks reinstall).
