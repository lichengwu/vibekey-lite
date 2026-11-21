#!/bin/sh
# VibeKey Lite 一键验收脚本（M2 灯效 + QwenWork + M1 回归）
#
# 用法:
#   ./scripts/acceptance.sh offline     # 离线：swift test 跑全部自动断言（mock 设备，不碰硬件）
#   ./scripts/acceptance.sh live        # 真机：自动断言 + 逐状态保持 + 佐井操作项暂停确认
#
# 红线：live 模式只写 0x0B 灯控组；不碰固件/配对/重置；不动 config.json；
#       不自动装回 WorkBuddy hooks（由佐井决定）。
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CTL="/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl"
MODE=${1:-offline}

cd "$PROJECT_DIR"

echo "=== 阶段 0：自动断言（离线 mock，全部可机器判定）==="
swift test --disable-sandbox --filter VibeKeyAcceptanceHarnessTests 2>&1 | grep -E "Test Suite 'VibeKeyAcceptanceHarnessTests'|Executed [0-9]+ tests" | tail -3
echo "自动断言覆盖：A1-A6 六状态帧契约 / B1-B3 QwenWork 映射+鉴权+仲裁 / C1-C2 M1 决策+防抖回滚 / D1 基线恢复"
echo ""

if [ "$MODE" = "offline" ]; then
    echo "离线模式结束。真机验收请运行: ./scripts/acceptance.sh live"
    exit 0
fi

# ---- live 模式 ----
if [ ! -x "$CTL" ]; then
    echo "错误：未找到 $CTL（需先安装含 vibekeyctl 的 App 版本）" >&2
    exit 1
fi
if ! "$CTL" status >/dev/null 2>&1; then
    echo "错误：VibeKey Lite 未运行或 socket 不通。请先启动 App。" >&2
    exit 1
fi

pause_for_user() {
    # $1 = 佐井操作说明
    echo ""
    echo "┌─ 佐井操作 ─────────────────────────────────────"
    echo "│ $1"
    echo "└────────────────────────────────────────────────"
    printf "完成后按 Enter 继续（输入 s 跳过本项）: "
    read -r answer
    if [ "$answer" = "s" ]; then echo "（已跳过）"; fi
}

hold_state() {
    # $1 = state, $2 = seconds, $3 = 期望现象
    "$CTL" led --state "$1" >/dev/null
    echo ">>> 状态 $1 保持 $2 秒 —— 期望: $3"
    sleep "$2"
}

echo "=== 阶段 A：六状态真机渲染核对（A7 佐井操作）==="
echo "提示：thinking 灯位已确认=旋钮慢闪（2026-11-21 隔离观察）。"
pause_for_user "确认设备在线、Ulanzi Studio 已退出、WorkBuddy hooks 保持卸载（纯净环境）"
hold_state idle 3 "全灭（参照基准）"
hold_state thinking 8 "旋钮慢闪 1.2s（灯位已确认 2026-11-21）"
hold_state working 8 "旋钮常亮（亮度中档）"
hold_state attention 11 "中键亮约 10 秒后自动灭"
hold_state notification 8 "中+下快闪 0.6s，旋钮灭"
hold_state error 6 "全部灯全亮闪 3 次后回到 notification 快闪"
hold_state sweeping 8 "中→下→旋钮流水，0.5s 一步"
"$CTL" led --state idle >/dev/null
pause_for_user "A7：以上六段灯效是否与期望一致？（thinking 灯位已确认=旋钮；若发现不符再反馈 agent）"

echo ""
echo "=== 阶段 B：QwenWork 端到端（B4 佐井操作）==="
pause_for_user "B4：App 设置→Agent 灯效接入→QwenWork 点安装→复制配置→企业管理后台（安全管控→Hooks 规则）粘贴 7 事件→在千问办公跑一轮任务观察灯；完成后点卸载并清空后台规则。个人版无 hooks 能力则跳过（输入 s）"

echo ""
echo "=== 阶段 C：M1 自动切组回归（C3 佐井操作）==="
pause_for_user "C3：在 config.json 配置 appProfileMapping（参考 README 示例）后重启 App，切换前台 App 并按旋钮/三键确认动作随组变化；⌘Tab 快速切换不应连环切组。未配置映射则跳过（输入 s）"

echo ""
echo "=== 阶段 D：收尾（D2 佐井操作）==="
"$CTL" led --restore >/dev/null 2>&1 || "$CTL" led --state idle >/dev/null
pause_for_user "D2：确认设备灯回到基线；WorkBuddy hooks 是否装回由你决定（vibekeyctl install-hooks --agent codebuddy）"

echo ""
echo "验收流程结束。自动断言结果见阶段 0；人工项结论请反馈给巡检 agent。"