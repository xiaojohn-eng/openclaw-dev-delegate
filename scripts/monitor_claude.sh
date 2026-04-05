#!/usr/bin/env bash
# monitor_claude.sh — Claude Code 会话实时监控
# 用途：监控正在运行的 Claude Code 会话，提供真实进度信息
#
# 用法：
#   ./monitor_claude.sh --project-dir /root/my-project --task-id task_001
#
# 通常由 delegate_to_claude.sh 自动启动，以后台进程运行

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
INTERVAL=30  # 每 30 秒检查一次

PROJECT_DIR=""
TASK_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --task-id)     TASK_ID="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$PROJECT_DIR" || -z "$TASK_ID" ]]; then
  exit 1
fi

MONITOR_LOG="$STATE_DIR/${TASK_ID}_monitor.log"
PROGRESS_FILE="$STATE_DIR/${TASK_ID}_progress.json"

# 初始化进度文件
echo '{"status":"running","checks":[],"last_update":"'"$(date -Iseconds)"'"}' > "$PROGRESS_FILE"

log_progress() {
  local msg="$1"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  echo "[$timestamp] $msg" >> "$MONITOR_LOG"

  # 更新进度 JSON
  python3 -c "
import json
try:
    with open('$PROGRESS_FILE') as f:
        data = json.load(f)
except:
    data = {'status':'running','checks':[],'last_update':''}

data['checks'].append({'time':'$timestamp','msg':'''$msg'''})
data['last_update'] = '$(date -Iseconds)'

# 只保留最近 50 条
data['checks'] = data['checks'][-50:]

with open('$PROGRESS_FILE','w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
" 2>/dev/null || true
}

log_progress "监控启动 | 项目: $PROJECT_DIR | 任务: $TASK_ID"

LAST_FILE_COUNT=0
LAST_TOTAL_SIZE=0

while true; do
  sleep "$INTERVAL"

  # 检查 Claude Code 是否还在跑
  if ! pgrep -af "claude.*-p" >/dev/null 2>&1; then
    # 也检查 lock.pid
    if [[ -f "$STATE_DIR/lock.pid" ]]; then
      LOCK_PID=$(cat "$STATE_DIR/lock.pid")
      if ! kill -0 "$LOCK_PID" 2>/dev/null; then
        log_progress "Claude Code 进程已结束"
        # 更新状态
        python3 -c "
import json
with open('$PROGRESS_FILE') as f: data = json.load(f)
data['status'] = 'completed'
with open('$PROGRESS_FILE','w') as f: json.dump(data, f, ensure_ascii=False, indent=2)
" 2>/dev/null || true
        break
      fi
    else
      log_progress "Claude Code 进程已结束（无锁文件）"
      break
    fi
  fi

  # 统计项目目录文件变化
  CURRENT_FILE_COUNT=$(find "$PROJECT_DIR" \
    -not -path '*/.git/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/.dev-delegate/*' \
    -type f 2>/dev/null | wc -l || echo 0)

  CURRENT_TOTAL_SIZE=$(du -sb "$PROJECT_DIR" --exclude='.git' --exclude='node_modules' --exclude='__pycache__' 2>/dev/null | awk '{print $1}' || echo 0)

  # 最近修改的文件
  RECENTLY_MODIFIED=$(find "$PROJECT_DIR" \
    -not -path '*/.git/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*/node_modules/*' \
    -type f -mmin -1 2>/dev/null | head -5 || true)

  NEW_FILES=$((CURRENT_FILE_COUNT - LAST_FILE_COUNT))
  SIZE_DIFF=$((CURRENT_TOTAL_SIZE - LAST_TOTAL_SIZE))

  if [[ -n "$RECENTLY_MODIFIED" ]]; then
    RECENT_LIST=$(echo "$RECENTLY_MODIFIED" | sed "s|$PROJECT_DIR/||g" | tr '\n' ', ' | sed 's/,$//')
    log_progress "活跃 | 文件数: $CURRENT_FILE_COUNT (+$NEW_FILES) | 最近修改: $RECENT_LIST"
  else
    log_progress "等待中 | 文件数: $CURRENT_FILE_COUNT | 无新变更"
  fi

  LAST_FILE_COUNT=$CURRENT_FILE_COUNT
  LAST_TOTAL_SIZE=$CURRENT_TOTAL_SIZE
done

log_progress "监控结束"
