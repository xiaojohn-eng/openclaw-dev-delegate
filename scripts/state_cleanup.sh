#!/usr/bin/env bash
# state_cleanup.sh — dev-delegate 状态目录清理与归档
# 用途：清理过期的运行时状态文件，防止 state/ 目录无限膨胀
#
# 用法：
#   ./state_cleanup.sh                    # 预览可清理的文件（dry-run）
#   ./state_cleanup.sh --execute          # 实际执行清理
#   ./state_cleanup.sh --archive          # 归档后清理（压缩到 state/archive/）
#   ./state_cleanup.sh --max-age 7        # 只清理 7 天前的文件（默认 30）
#   ./state_cleanup.sh --json             # JSON 格式输出
#
# 退出码：
#   0 = 正常完成
#   1 = 参数错误

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"

DRY_RUN=true
ARCHIVE=false
MAX_AGE_DAYS=30
JSON_OUTPUT=false

show_help() {
  cat <<'HELPEOF'
state_cleanup.sh — dev-delegate 状态目录清理与归档

用法：
  ./state_cleanup.sh                    # 预览可清理的文件（dry-run）
  ./state_cleanup.sh --execute          # 实际执行清理
  ./state_cleanup.sh --archive          # 归档后清理（压缩到 state/archive/）
  ./state_cleanup.sh --max-age DAYS     # 只清理 N 天前的文件（默认 30）
  ./state_cleanup.sh --json             # JSON 格式输出

参数：
  --execute        实际执行清理（默认为 dry-run 预览）
  --archive        归档模式：先打包再删除
  --max-age DAYS   文件保留天数（默认 30）
  --json           以 JSON 格式输出清理报告
  -h, --help       显示此帮助信息

保护规则：
  - 永远不删除 active_task.json（当前活跃任务）
  - 永远不删除 call_log.jsonl（调用日志，仅截断）
  - 不删除仍在运行的任务的关联文件（通过 PID 判断）
  - lock.pid 由 startup_check.sh 管理，此脚本不处理

退出码：
  0 = 正常完成
  1 = 参数错误
HELPEOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    show_help ;;
    --execute)    DRY_RUN=false; shift ;;
    --archive)    ARCHIVE=true; DRY_RUN=false; shift ;;
    --max-age)    MAX_AGE_DAYS="$2"; shift 2 ;;
    --json)       JSON_OUTPUT=true; shift ;;
    *) echo "未知参数: $1"; echo "使用 $0 --help 查看用法"; exit 1 ;;
  esac
done

if [[ ! -d "$STATE_DIR" ]]; then
  [[ "$JSON_OUTPUT" == "true" ]] && echo '{"cleaned":0,"skipped":0,"errors":0,"message":"state目录不存在"}'
  [[ "$JSON_OUTPUT" != "true" ]] && echo "state 目录不存在: $STATE_DIR"
  exit 0
fi

# ─── 收集运行中任务的 task_id（保护其文件） ───
RUNNING_TASKS=()
for pid_file in "$STATE_DIR"/*_bg.pid "$STATE_DIR"/lock.pid; do
  [[ -f "$pid_file" ]] || continue
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    # 从文件名提取 task_id
    base=$(basename "$pid_file")
    case "$base" in
      lock.pid)
        # 从 active_task.json 读取 task_id
        if [[ -f "$STATE_DIR/active_task.json" ]]; then
          tid=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_id',''))" < "$STATE_DIR/active_task.json" 2>/dev/null || true)
          [[ -n "$tid" ]] && RUNNING_TASKS+=("$tid")
        fi
        ;;
      *_bg.pid)
        tid="${base%_bg.pid}"
        RUNNING_TASKS+=("$tid")
        ;;
    esac
  fi
done

is_running_task() {
  local file_base="$1"
  for tid in "${RUNNING_TASKS[@]+"${RUNNING_TASKS[@]}"}"; do
    [[ "$file_base" == "${tid}_"* || "$file_base" == "${tid}."* ]] && return 0
  done
  return 1
}

# ─── 扫描可清理文件 ───
CLEAN_FILES=()
SKIP_FILES=()
TOTAL_SIZE=0

# 受保护文件名（不清理）
PROTECTED_FILES=("active_task.json" "call_log.jsonl" ".cli_caps_cache" "lock.pid")

is_protected() {
  local name="$1"
  for p in "${PROTECTED_FILES[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  # *_bg.pid 由 startup_check 管理
  [[ "$name" == *_bg.pid ]] && return 0
  return 1
}

while IFS= read -r filepath; do
  [[ -z "$filepath" ]] && continue
  filename=$(basename "$filepath")

  # 跳过受保护文件
  if is_protected "$filename"; then
    SKIP_FILES+=("$filepath|protected")
    continue
  fi

  # 跳过 archive 子目录
  [[ "$filepath" == "$STATE_DIR/archive/"* ]] && continue

  # 跳过运行中任务的文件
  if is_running_task "$filename"; then
    SKIP_FILES+=("$filepath|running")
    continue
  fi

  # 检查文件年龄
  file_size=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
  CLEAN_FILES+=("$filepath")
  TOTAL_SIZE=$((TOTAL_SIZE + file_size))
done < <(find "$STATE_DIR" -maxdepth 1 -type f -mtime "+${MAX_AGE_DAYS}" 2>/dev/null)

CLEAN_COUNT=${#CLEAN_FILES[@]}
SKIP_COUNT=${#SKIP_FILES[@]}

# ─── 人类可读大小 ───
human_size() {
  local bytes=$1
  if [[ $bytes -ge 1048576 ]]; then
    echo "$((bytes / 1048576))MB"
  elif [[ $bytes -ge 1024 ]]; then
    echo "$((bytes / 1024))KB"
  else
    echo "${bytes}B"
  fi
}

# ─── call_log.jsonl 截断（保留最近 500 条） ───
LOG_TRUNCATED=false
LOG_ORIGINAL_LINES=0
if [[ -f "$STATE_DIR/call_log.jsonl" ]]; then
  LOG_ORIGINAL_LINES=$(wc -l < "$STATE_DIR/call_log.jsonl")
  if [[ $LOG_ORIGINAL_LINES -gt 500 ]]; then
    LOG_TRUNCATED=true
  fi
fi

# ─── 执行 ───
ERRORS=0
if [[ "$DRY_RUN" == "false" && $CLEAN_COUNT -gt 0 ]]; then
  if [[ "$ARCHIVE" == "true" ]]; then
    ARCHIVE_DIR="$STATE_DIR/archive"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_NAME="cleanup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar czf "$ARCHIVE_DIR/$ARCHIVE_NAME" -C "$STATE_DIR" \
      $(printf '%s\n' "${CLEAN_FILES[@]}" | xargs -I{} basename {}) 2>/dev/null || ((ERRORS++))
  fi

  for f in "${CLEAN_FILES[@]}"; do
    rm -f "$f" 2>/dev/null || ((ERRORS++))
  done

  # 截断 call_log
  if [[ "$LOG_TRUNCATED" == "true" ]]; then
    tail -500 "$STATE_DIR/call_log.jsonl" > "$STATE_DIR/call_log.jsonl.tmp"
    mv "$STATE_DIR/call_log.jsonl.tmp" "$STATE_DIR/call_log.jsonl"
  fi
fi

# ─── 输出 ───
if [[ "$JSON_OUTPUT" == "true" ]]; then
  python3 -c "
import json
result = {
    'dry_run': $( [[ \"$DRY_RUN\" == \"true\" ]] && echo 'True' || echo 'False' ),
    'archive': $( [[ \"$ARCHIVE\" == \"true\" ]] && echo 'True' || echo 'False' ),
    'max_age_days': $MAX_AGE_DAYS,
    'cleaned_files': $CLEAN_COUNT,
    'cleaned_bytes': $TOTAL_SIZE,
    'cleaned_human': '$(human_size $TOTAL_SIZE)',
    'skipped_files': $SKIP_COUNT,
    'log_truncated': $( [[ \"$LOG_TRUNCATED\" == \"true\" ]] && echo 'True' || echo 'False' ),
    'log_original_lines': $LOG_ORIGINAL_LINES,
    'errors': $ERRORS,
    'running_tasks': $(python3 -c "import json; print(json.dumps([$(printf '"%s",' "${RUNNING_TASKS[@]+"${RUNNING_TASKS[@]}"}" | sed 's/,$//')]))" 2>/dev/null || echo '[]')
}
print(json.dumps(result, ensure_ascii=False, indent=2))
"
else
  echo "=== dev-delegate 状态清理 ==="
  echo "时间: $(date -Iseconds)"
  echo "最大保留天数: ${MAX_AGE_DAYS}"
  echo "模式: $( [[ "$DRY_RUN" == "true" ]] && echo "预览（dry-run）" || ([[ "$ARCHIVE" == "true" ]] && echo "归档后清理" || echo "直接清理") )"
  echo ""

  if [[ ${#RUNNING_TASKS[@]+"${#RUNNING_TASKS[@]}"} -gt 0 ]]; then
    echo "运行中任务（已保护）: ${RUNNING_TASKS[*]}"
    echo ""
  fi

  if [[ $CLEAN_COUNT -gt 0 ]]; then
    echo "可清理文件: $CLEAN_COUNT 个 ($(human_size $TOTAL_SIZE))"
    for f in "${CLEAN_FILES[@]}"; do
      echo "  - $(basename "$f")"
    done
  else
    echo "无需清理的过期文件"
  fi

  if [[ "$LOG_TRUNCATED" == "true" ]]; then
    echo ""
    echo "call_log.jsonl: ${LOG_ORIGINAL_LINES} 行 → 保留最近 500 行"
  fi

  echo ""
  echo "跳过: $SKIP_COUNT 个（受保护或运行中）"

  if [[ "$DRY_RUN" == "true" && $CLEAN_COUNT -gt 0 ]]; then
    echo ""
    echo "提示: 使用 --execute 实际执行清理，或 --archive 归档后清理"
  fi

  if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo "警告: 清理过程中有 $ERRORS 个错误"
  fi

  echo ""
  echo "=== 清理完成 ==="
fi
