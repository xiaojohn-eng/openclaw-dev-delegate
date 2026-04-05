#!/usr/bin/env bash
# subscription_guard.sh — 订阅配额保护脚本
# 用途：调用 Claude Code 前检查配额、并发、用户优先级
#
# 用法：
#   ./subscription_guard.sh --check          # 检查是否可以调用
#   ./subscription_guard.sh --status         # 查看当前配额状态
#   ./subscription_guard.sh --wait           # 等待直到可以调用
#
# 退出码：
#   0 = 可以调用
#   1 = 不可以调用（附带原因）

set -uo pipefail

# 检查 python3 可用性
if ! command -v python3 &>/dev/null; then
  echo "❌ python3 不可用，subscription_guard.sh 无法执行"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR"
CALL_LOG="$STATE_DIR/call_log.jsonl"

# ─── 配置 ───
MAX_CALLS_PER_HOUR=10
MAX_CALLS_PER_DAY=50
MIN_INTERVAL_SECONDS=30
RATE_LIMIT_WAIT=300  # 5分钟

ACTION="${1:---check}"

# ─── 工具函数 ───
now_epoch() { date +%s; }
now_iso() { date -Iseconds; }

count_calls_since() {
  local since_epoch=$1
  if [[ ! -f "$CALL_LOG" ]]; then
    echo 0
    return
  fi
  python3 -c "
import json, sys
from datetime import datetime, timezone
count = 0
since = $since_epoch
for line in open('$CALL_LOG'):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        ct = d.get('call_time','')
        # 解析 ISO 时间
        ts = datetime.fromisoformat(ct.replace('Z','+00:00')).timestamp()
        if ts >= since:
            count += 1
    except: pass
print(count)
" 2>/dev/null || echo 0
}

last_call_epoch() {
  if [[ ! -f "$CALL_LOG" ]]; then
    echo 0
    return
  fi
  python3 -c "
import json
from datetime import datetime
last = 0
for line in open('$CALL_LOG'):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        ct = d.get('call_time','')
        ts = datetime.fromisoformat(ct.replace('Z','+00:00')).timestamp()
        if ts > last: last = ts
    except: pass
print(int(last))
" 2>/dev/null || echo 0
}

# ─── 检查 1：用户是否在使用 Claude Code ───
check_user_active() {
  # H-06 修复：使用精确匹配，避免匹配到 "vim CLAUDE.md" 等无关进程
  # 检查是否有交互式 Claude Code 会话（非 -p 模式）
  local interactive_count=0
  while IFS= read -r line; do
    # 跳过包含 -p 的（OpenClaw 调用的 pipe 模式）
    [[ "$line" == *" -p "* ]] && continue
    # 跳过脚本自身
    [[ "$line" == *"delegate_to_claude"* ]] && continue
    [[ "$line" == *"monitor_claude"* ]] && continue
    [[ "$line" == *"subscription_guard"* ]] && continue
    ((interactive_count++)) || true
  done < <(pgrep -x claude -a 2>/dev/null || true)

  if [[ "$interactive_count" -gt 0 ]]; then
    echo "USER_ACTIVE"
    return 1
  fi
  echo "USER_IDLE"
  return 0
}

# ─── 检查 2：是否有其他 Claude Code 会话在跑 ───
check_concurrent() {
  # H-06 修复：使用 pgrep -x 精确匹配可执行文件名
  local claude_p_count=0
  while IFS= read -r line; do
    [[ "$line" == *" -p "* ]] && ((claude_p_count++)) || true
  done < <(pgrep -x claude -a 2>/dev/null || true)

  if [[ "$claude_p_count" -gt 0 ]]; then
    echo "CONCURRENT_SESSION"
    return 1
  fi

  # 也检查任务锁
  if [[ -f "$STATE_DIR/lock.pid" ]]; then
    local lock_pid
    lock_pid=$(cat "$STATE_DIR/lock.pid")
    if kill -0 "$lock_pid" 2>/dev/null; then
      echo "TASK_LOCKED:$lock_pid"
      return 1
    else
      # 过期锁，清理
      rm -f "$STATE_DIR/lock.pid"
    fi
  fi

  echo "NO_CONCURRENT"
  return 0
}

# ─── 检查 3：调用间隔 ───
check_interval() {
  local last_epoch
  last_epoch=$(last_call_epoch)
  local now
  now=$(now_epoch)
  local diff=$((now - last_epoch))

  if [[ $diff -lt $MIN_INTERVAL_SECONDS && $last_epoch -gt 0 ]]; then
    local wait=$((MIN_INTERVAL_SECONDS - diff))
    echo "TOO_FAST:${wait}s"
    return 1
  fi
  echo "INTERVAL_OK"
  return 0
}

# ─── 检查 4：小时配额 ───
check_hourly() {
  local one_hour_ago
  one_hour_ago=$(( $(now_epoch) - 3600 ))
  local count
  count=$(count_calls_since "$one_hour_ago")

  if [[ "$count" -ge "$MAX_CALLS_PER_HOUR" ]]; then
    echo "HOURLY_LIMIT:${count}/${MAX_CALLS_PER_HOUR}"
    return 1
  fi
  echo "HOURLY_OK:${count}/${MAX_CALLS_PER_HOUR}"
  return 0
}

# ─── 检查 5：日配额 ───
check_daily() {
  local today_start
  today_start=$(date -d "today 00:00:00" +%s 2>/dev/null || date -d "$(date +%Y-%m-%d)" +%s 2>/dev/null || echo 0)
  local count
  count=$(count_calls_since "$today_start")

  if [[ "$count" -ge "$MAX_CALLS_PER_DAY" ]]; then
    echo "DAILY_LIMIT:${count}/${MAX_CALLS_PER_DAY}"
    return 1
  fi
  echo "DAILY_OK:${count}/${MAX_CALLS_PER_DAY}"
  return 0
}

# ─── 主逻辑 ───
case "$ACTION" in
  --check)
    BLOCKED=false
    REASONS=""

    # 用户优先级
    USER_STATUS=$(check_user_active 2>/dev/null) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 用户正在使用 Claude Code，OpenClaw 需等待"
    }

    # 并发检查
    CONC_STATUS=$(check_concurrent 2>/dev/null) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 已有 Claude Code 会话在运行: $CONC_STATUS"
    }

    # 调用间隔
    INTERVAL_STATUS=$(check_interval 2>/dev/null) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 调用间隔过短: $INTERVAL_STATUS"
    }

    # 小时配额
    HOURLY_STATUS=$(check_hourly 2>/dev/null) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 小时配额已满: $HOURLY_STATUS"
    }

    # 日配额
    DAILY_STATUS=$(check_daily 2>/dev/null) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 日配额已满: $DAILY_STATUS"
    }

    if [[ "$BLOCKED" == "true" ]]; then
      echo "🚫 不可调用 Claude Code"
      echo -e "$REASONS"
      exit 1
    else
      echo "🟢 可以调用 Claude Code"
      echo "  用户状态: $USER_STATUS"
      echo "  并发状态: $CONC_STATUS"
      echo "  调用间隔: $INTERVAL_STATUS"
      echo "  小时配额: $HOURLY_STATUS"
      echo "  日配额: $DAILY_STATUS"
      exit 0
    fi
    ;;

  --status)
    echo "=== 订阅配额状态 ==="
    echo "用户状态: $(check_user_active 2>/dev/null || echo 'ACTIVE')"
    echo "并发状态: $(check_concurrent 2>/dev/null || echo 'CONCURRENT')"
    echo "调用间隔: $(check_interval 2>/dev/null || echo 'TOO_FAST')"
    echo "小时配额: $(check_hourly 2>/dev/null || echo 'LIMIT')"
    echo "日配额:   $(check_daily 2>/dev/null || echo 'LIMIT')"
    if [[ -f "$CALL_LOG" ]]; then
      TOTAL_CALLS=$(wc -l < "$CALL_LOG")
      echo "总调用次数: $TOTAL_CALLS"
    fi
    ;;

  --wait)
    echo "⏳ 等待调用条件满足..."
    ATTEMPTS=0
    MAX_ATTEMPTS=60  # 最多等 30 分钟
    while ! "$0" --check >/dev/null 2>&1; do
      ((ATTEMPTS++))
      if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
        echo "❌ 等待超时（${MAX_ATTEMPTS} 次尝试）"
        exit 1
      fi
      sleep 30
    done
    echo "✅ 条件满足，可以调用"
    ;;

  *)
    echo "用法: $0 [--check|--status|--wait]"
    exit 1
    ;;
esac
