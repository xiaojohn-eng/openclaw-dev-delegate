#!/usr/bin/env bash
# startup_check.sh — OpenClaw 启动时自检
# 用途：检查是否有未完成/未汇报的后台任务，恢复断点状态
#
# 用法：
#   ./startup_check.sh              # 检查所有任务
#   ./startup_check.sh --cleanup    # 清理已确认的过期状态

set -uo pipefail

if ! command -v python3 &>/dev/null; then
  echo "❌ python3 不可用"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR"

ACTION="${1:---check}"

echo "=== dev-delegate 启动自检 ==="
echo "时间: $(date -Iseconds)"
echo ""

RUNNING=0
COMPLETED_UNREPORTED=0
CRASHED=0
STALE=0

# ─── 检查所有任务状态 ───
for bg_pid_file in "$STATE_DIR"/*_bg.pid; do
  [[ -f "$bg_pid_file" ]] || continue
  TASK_ID=$(basename "$bg_pid_file" _bg.pid)
  BG_PID=$(cat "$bg_pid_file")
  DONE_FILE="$STATE_DIR/${TASK_ID}_done.json"
  OUTPUT_FILE="$STATE_DIR/${TASK_ID}_output.txt"

  if kill -0 "$BG_PID" 2>/dev/null; then
    # 进程还活着
    echo "🔵 运行中: $TASK_ID (PID: $BG_PID)"
    MONITOR_LOG="$STATE_DIR/${TASK_ID}_monitor.log"
    if [[ -f "$MONITOR_LOG" ]]; then
      echo "   最近状态: $(tail -1 "$MONITOR_LOG")"
    fi
    ((RUNNING++))

  elif [[ -f "$DONE_FILE" ]]; then
    # 进程已结束，有完成标记
    DONE_INFO=$(cat "$DONE_FILE")
    EXIT_CODE=$(python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('exit_code',99))" < "$DONE_FILE" 2>/dev/null || echo "?")

    if [[ "$EXIT_CODE" == "0" ]]; then
      echo "🟡 已完成但未汇报: $TASK_ID"
      echo "   完成信息: $DONE_INFO"
      echo "   👉 请执行 verify_delivery.sh 验证并汇报用户"
      ((COMPLETED_UNREPORTED++))
    else
      echo "🔴 异常完成: $TASK_ID (退出码: $EXIT_CODE)"
      if [[ -f "$STATE_DIR/${TASK_ID}_stderr.txt" ]]; then
        echo "   错误: $(tail -3 "$STATE_DIR/${TASK_ID}_stderr.txt")"
      fi
      ((CRASHED++))
    fi

  else
    # 进程已结束，无完成标记 → 崩溃
    echo "🔴 异常中断: $TASK_ID (PID $BG_PID 已不存在)"
    if [[ -f "$OUTPUT_FILE" && -s "$OUTPUT_FILE" ]]; then
      OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || echo 0)
      echo "   部分输出: ${OUTPUT_SIZE} bytes"
      echo "   👉 可尝试 crash_recover.sh 断点续接"
    else
      echo "   无输出，可能刚启动就失败了"
    fi
    ((CRASHED++))
  fi
done

# ─── 检查过期的锁文件 ───
if [[ -f "$STATE_DIR/lock.pid" ]]; then
  LOCK_PID=$(cat "$STATE_DIR/lock.pid")
  if ! kill -0 "$LOCK_PID" 2>/dev/null; then
    echo ""
    echo "⚠️ 发现过期锁文件 (PID: $LOCK_PID 已不存在)"
    if [[ "$ACTION" == "--cleanup" ]]; then
      rm -f "$STATE_DIR/lock.pid"
      echo "   已清理"
    else
      echo "   执行 $0 --cleanup 清理"
    fi
    ((STALE++))
  fi
fi

# ─── 清理模式 ───
if [[ "$ACTION" == "--cleanup" ]]; then
  echo ""
  echo "🧹 清理过期状态..."
  for bg_pid_file in "$STATE_DIR"/*_bg.pid; do
    [[ -f "$bg_pid_file" ]] || continue
    BG_PID=$(cat "$bg_pid_file")
    if ! kill -0 "$BG_PID" 2>/dev/null; then
      rm -f "$bg_pid_file"
      echo "   已清理: $(basename "$bg_pid_file")"
    fi
  done
  rm -f "$STATE_DIR/lock.pid" 2>/dev/null || true
  echo "   完成"
fi

# ─── 汇总 ───
echo ""
echo "─────────────────"
echo "运行中: $RUNNING"
echo "已完成未汇报: $COMPLETED_UNREPORTED"
echo "异常中断: $CRASHED"
echo "过期状态: $STALE"

if [[ $COMPLETED_UNREPORTED -gt 0 ]]; then
  echo ""
  echo "⚡ 有 $COMPLETED_UNREPORTED 个任务完成后未汇报用户，请尽快处理"
fi
if [[ $CRASHED -gt 0 ]]; then
  echo ""
  echo "⚡ 有 $CRASHED 个任务异常中断，请检查是否需要恢复"
fi

echo ""
echo "=== 自检完成 ==="
