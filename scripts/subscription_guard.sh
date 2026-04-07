#!/usr/bin/env bash
# subscription_guard.sh — 订阅配额保护脚本
# 用途：调用 Claude Code 前检查配额、并发、用户优先级
#
# 用法：
#   ./subscription_guard.sh --check          # 检查是否可以调用
#   ./subscription_guard.sh --status         # 查看当前配额状态
#   ./subscription_guard.sh --wait           # 等待直到可以调用
#
# 环境变量：
#   DEV_DELEGATE_SKIP_USER_CHECK=1   跳过用户活跃检查（默认跳过）
#   DEV_DELEGATE_STRICT_USER_CHECK=1 强制启用用户活跃检查（保守模式）
#
# 退出码：
#   0 = 可以调用
#   1 = 不可以调用（附带原因）

set -uo pipefail

if ! command -v python3 &>/dev/null; then
  echo "❌ python3 不可用"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR"
CALL_LOG="$STATE_DIR/call_log.jsonl"

# ─── 配置 ───
MAX_CALLS_PER_HOUR="${DEV_DELEGATE_MAX_CALLS_PER_HOUR:-10}"
MAX_CALLS_PER_DAY="${DEV_DELEGATE_MAX_CALLS_PER_DAY:-50}"
MIN_INTERVAL_SECONDS="${DEV_DELEGATE_MIN_INTERVAL:-30}"

# 用户活跃检查策略：默认不检查（允许并行），设 STRICT=1 才启用
STRICT_USER_CHECK="${DEV_DELEGATE_STRICT_USER_CHECK:-0}"

ACTION="${1:---check}"

# ─── 工具函数 ───
now_epoch() { date +%s; }

count_calls_since() {
  local since_epoch=$1
  [[ ! -f "$CALL_LOG" ]] && { echo 0; return; }
  python3 -c "
import json, sys
from datetime import datetime
count = 0
since = int(sys.argv[1])
for line in open(sys.argv[2]):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        ts = datetime.fromisoformat(d.get('call_time','').replace('Z','+00:00')).timestamp()
        if ts >= since: count += 1
    except: pass
print(count)
" "$since_epoch" "$CALL_LOG" 2>/dev/null || echo 0
}

last_call_epoch() {
  [[ ! -f "$CALL_LOG" ]] && { echo 0; return; }
  python3 -c "
import json, sys
from datetime import datetime
last = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        ts = datetime.fromisoformat(d.get('call_time','').replace('Z','+00:00')).timestamp()
        if ts > last: last = ts
    except: pass
print(int(last))
" "$CALL_LOG" 2>/dev/null || echo 0
}

# ─── 精确列出 claude CLI 进程 ───
list_claude_processes() {
  # 遍历所有进程，通过 /proc/PID/exe 和 /proc/PID/cmdline 精确判断
  for pid_dir in /proc/[0-9]*/; do
    local pid="${pid_dir#/proc/}"
    pid="${pid%/}"
    [[ "$pid" == "$$" ]] && continue  # 跳过自身
    [[ "$pid" == "$PPID" ]] && continue  # 跳过父进程

    local exe_name cmdline
    exe_name=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    [[ -z "$exe_name" ]] && continue

    # 条件1: 可执行文件名就是 claude
    if [[ "$(basename "$exe_name")" == "claude" ]]; then
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      echo "$pid $cmdline"
      continue
    fi

    # 条件2: node 进程，且 cmdline 中第二个参数（脚本路径）以 /claude 结尾
    if [[ "$(basename "$exe_name")" == "node" ]]; then
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      # 提取 node 后的第一个参数（脚本路径）
      local script_path
      script_path=$(echo "$cmdline" | awk '{print $2}')
      if [[ "$(basename "$script_path" 2>/dev/null)" == "claude" ]]; then
        echo "$pid $cmdline"
      fi
    fi
  done
}

# ─── 检查 1：用户是否在使用 Claude Code ───
check_user_active() {
  # 如果非严格模式，直接放行
  if [[ "$STRICT_USER_CHECK" != "1" ]]; then
    echo "SKIPPED"
    return 0
  fi

  local interactive_count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # 跳过 pipe 模式（-p = OpenClaw 调用）
    [[ "$line" == *" -p "* ]] && continue
    # 跳过 dev-delegate 脚本
    [[ "$line" == *"delegate_to_claude"* ]] && continue
    [[ "$line" == *"monitor_claude"* ]] && continue
    [[ "$line" == *"subscription_guard"* ]] && continue
    ((interactive_count++)) || true
  done < <(list_claude_processes)

  if [[ "$interactive_count" -gt 0 ]]; then
    echo "USER_ACTIVE:${interactive_count}"
    return 1
  fi
  echo "USER_IDLE"
  return 0
}

# ─── 检查 2：是否有其他 OpenClaw 委托的 Claude Code 在跑 ───
check_concurrent() {
  # 只检查 pipe 模式（-p）的 claude 进程 = OpenClaw 委托的会话
  local claude_p_count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == *" -p "* ]] && ((claude_p_count++)) || true
  done < <(list_claude_processes)

  if [[ "$claude_p_count" -gt 0 ]]; then
    echo "CONCURRENT_SESSION:${claude_p_count}"
    return 1
  fi

  # 检查任务锁
  if [[ -f "$STATE_DIR/lock.pid" ]]; then
    local lock_pid
    lock_pid=$(cat "$STATE_DIR/lock.pid")
    if kill -0 "$lock_pid" 2>/dev/null; then
      echo "TASK_LOCKED:$lock_pid"
      return 1
    else
      rm -f "$STATE_DIR/lock.pid"
    fi
  fi

  echo "NO_CONCURRENT"
  return 0
}

# ─── 检查 3：调用间隔 ───
check_interval() {
  local last_epoch now diff
  last_epoch=$(last_call_epoch)
  now=$(now_epoch)
  diff=$((now - last_epoch))

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
  local one_hour_ago count
  one_hour_ago=$(( $(now_epoch) - 3600 ))
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
  local today_start count
  today_start=$(date -d "today 00:00:00" +%s 2>/dev/null || date -d "$(date +%Y-%m-%d)" +%s 2>/dev/null || echo 0)
  count=$(count_calls_since "$today_start")

  if [[ "$count" -ge "$MAX_CALLS_PER_DAY" ]]; then
    echo "DAILY_LIMIT:${count}/${MAX_CALLS_PER_DAY}"
    return 1
  fi
  echo "DAILY_OK:${count}/${MAX_CALLS_PER_DAY}"
  return 0
}

# ─── 安全捕获检查结果（避免重复输出） ───
safe_check() {
  local result
  result=$("$@" 2>/dev/null)
  local rc=$?
  echo "$result"
  return $rc
}

# ─── 主逻辑 ───
case "$ACTION" in
  --check)
    BLOCKED=false
    REASONS=""

    # 用户优先级（默认跳过，STRICT=1 才检查）
    USER_STATUS=$(safe_check check_user_active) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 用户正在使用 Claude Code ($USER_STATUS)"
    }

    # 并发检查（只检查 OpenClaw 委托的 -p 模式会话）
    CONC_STATUS=$(safe_check check_concurrent) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 已有委托会话在运行: $CONC_STATUS"
    }

    # 调用间隔
    INTERVAL_STATUS=$(safe_check check_interval) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 调用间隔过短: $INTERVAL_STATUS"
    }

    # 小时配额
    HOURLY_STATUS=$(safe_check check_hourly) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 小时配额已满: $HOURLY_STATUS"
    }

    # 日配额
    DAILY_STATUS=$(safe_check check_daily) || {
      BLOCKED=true
      REASONS="${REASONS}\n❌ 日配额已满: $DAILY_STATUS"
    }

    if [[ "$BLOCKED" == "true" ]]; then
      echo "🚫 不可调用 Claude Code"
      echo -e "$REASONS"
      exit 1
    else
      echo "🟢 可以调用 Claude Code"
      echo "  用户检查: $USER_STATUS"
      echo "  并发状态: $CONC_STATUS"
      echo "  调用间隔: $INTERVAL_STATUS"
      echo "  小时配额: $HOURLY_STATUS"
      echo "  日配额: $DAILY_STATUS"
      exit 0
    fi
    ;;

  --status)
    echo "=== 订阅配额状态 ==="
    echo "用户检查: $(safe_check check_user_active)"
    echo "并发状态: $(safe_check check_concurrent)"
    echo "调用间隔: $(safe_check check_interval)"
    echo "小时配额: $(safe_check check_hourly)"
    echo "日配额:   $(safe_check check_daily)"
    echo "严格模式: $([ "$STRICT_USER_CHECK" = "1" ] && echo '开启' || echo '关闭（默认）')"
    if [[ -f "$CALL_LOG" ]]; then
      echo "总调用次数: $(wc -l < "$CALL_LOG")"
    fi
    ;;

  --wait)
    echo "⏳ 等待调用条件满足..."
    ATTEMPTS=0
    MAX_ATTEMPTS=60
    while ! "$0" --check >/dev/null 2>&1; do
      ((ATTEMPTS++)) || true
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
