#!/usr/bin/env bash
# delegate_to_claude.sh — 标准化 Claude Code 调用脚本
# 用途：OpenClaw 通过此脚本调用 Claude Code，禁止任何其他方式
#
# 用法：
#   # 前台模式（阻塞等待完成）
#   ./delegate_to_claude.sh \
#     --project-dir /root/my-project \
#     --task-id task_001 \
#     --task-brief /path/to/task_brief.md \
#     [--timeout 600]
#
#   # 后台模式（立即返回，Claude Code 后台执行）
#   ./delegate_to_claude.sh \
#     --project-dir /root/my-project \
#     --task-id task_001 \
#     --task-brief /path/to/task_brief.md \
#     --background
#
#   # 查询后台任务状态
#   ./delegate_to_claude.sh --status --task-id task_001
#
# 退出码：
#   0 = 成功（前台模式）/ 已启动（后台模式）
#   1 = 参数错误
#   2 = 前置检查失败（配额/并发/用户优先）
#   3 = Claude Code 调用失败
#   4 = 超时

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
CLAUDE_BIN="${CLAUDE_BIN:-/root/.nvm/versions/node/v22.22.2/bin/claude}"
CALL_LOG="$STATE_DIR/call_log.jsonl"
DEFAULT_TIMEOUT=1800  # 30 分钟（大任务需要更多时间）

# ─── 参数解析 ───
PROJECT_DIR=""
TASK_ID=""
TASK_BRIEF=""
TIMEOUT=$DEFAULT_TIMEOUT
BACKGROUND=false
CHECK_STATUS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)  PROJECT_DIR="$2"; shift 2 ;;
    --task-id)      TASK_ID="$2"; shift 2 ;;
    --task-brief)   TASK_BRIEF="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --background)   BACKGROUND=true; shift ;;
    --status)       CHECK_STATUS=true; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ─── 状态查询模式 ───
if [[ "$CHECK_STATUS" == "true" ]]; then
  if [[ -z "$TASK_ID" ]]; then
    echo "❌ --status 需要 --task-id"
    exit 1
  fi

  ACTIVE_FILE="$STATE_DIR/active_task.json"
  PROGRESS_FILE="$STATE_DIR/${TASK_ID}_progress.json"
  MONITOR_LOG="$STATE_DIR/${TASK_ID}_monitor.log"
  OUTPUT_FILE="$STATE_DIR/${TASK_ID}_output.txt"
  BG_PID_FILE="$STATE_DIR/${TASK_ID}_bg.pid"

  echo "=== 任务状态：$TASK_ID ==="

  # 检查后台进程是否还活着
  if [[ -f "$BG_PID_FILE" ]]; then
    BG_PID=$(cat "$BG_PID_FILE")
    if kill -0 "$BG_PID" 2>/dev/null; then
      echo "📍 状态：运行中（PID: $BG_PID）"
    else
      echo "📍 状态：已结束"
    fi
  elif [[ -f "$STATE_DIR/lock.pid" ]]; then
    LOCK_PID=$(cat "$STATE_DIR/lock.pid")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
      echo "📍 状态：运行中（PID: $LOCK_PID）"
    else
      echo "📍 状态：已结束"
    fi
  else
    echo "📍 状态：未启动或已结束"
  fi

  # 显示最近的监控日志
  if [[ -f "$MONITOR_LOG" ]]; then
    echo ""
    echo "📊 最近进度："
    tail -5 "$MONITOR_LOG"
  fi

  # 如果已完成，显示结果摘要
  if [[ -f "$OUTPUT_FILE" && -s "$OUTPUT_FILE" ]]; then
    echo ""
    echo "📋 Claude Code 输出（最后 20 行）："
    tail -20 "$OUTPUT_FILE"
  fi

  # 显示调用日志
  if [[ -f "$CALL_LOG" ]]; then
    TASK_LOG=$(grep "\"$TASK_ID\"" "$CALL_LOG" | tail -1)
    if [[ -n "$TASK_LOG" ]]; then
      echo ""
      echo "📝 调用记录："
      echo "$TASK_LOG" | python3 -m json.tool 2>/dev/null || echo "$TASK_LOG"
    fi
  fi

  exit 0
fi

# ─── 参数校验 ───
if [[ -z "$PROJECT_DIR" || -z "$TASK_ID" || -z "$TASK_BRIEF" ]]; then
  echo "❌ 缺少必要参数"
  echo "用法: $0 --project-dir DIR --task-id ID --task-brief FILE"
  exit 1
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "❌ 项目目录不存在: $PROJECT_DIR"
  exit 1
fi

if [[ ! -f "$TASK_BRIEF" ]]; then
  echo "❌ 任务简报文件不存在: $TASK_BRIEF"
  exit 1
fi

# ─── 前置检查：订阅配额保护 ───
echo "🔍 执行前置检查..."

GUARD_RESULT=$("$SCRIPT_DIR/subscription_guard.sh" --check 2>&1) || {
  echo "❌ 前置检查未通过："
  echo "$GUARD_RESULT"
  exit 2
}
echo "✅ 前置检查通过"

# ─── 前置检查：任务简报质量 ───
echo "🔍 校验任务简报..."

BRIEF_RESULT=$("$SCRIPT_DIR/task_brief_validator.sh" "$TASK_BRIEF" 2>&1) || {
  echo "❌ 任务简报质量不合格："
  echo "$BRIEF_RESULT"
  exit 1
}
echo "✅ 任务简报合格"

# ─── 环境快照（前） ───
echo "📸 拍摄环境快照（前）..."
"$SCRIPT_DIR/env_snapshot.sh" --before --project-dir "$PROJECT_DIR" --task-id "$TASK_ID"

# ─── Git Checkpoint ───
echo "📸 创建 Git 快照..."
"$SCRIPT_DIR/checkpoint.sh" --create --project-dir "$PROJECT_DIR" --label "before_${TASK_ID}"

# ─── 构建 Claude Code Prompt ───
BRIEF_CONTENT=$(cat "$TASK_BRIEF")

PROMPT="你现在收到一个开发任务，请严格按要求执行。

## 任务简报
${BRIEF_CONTENT}

## 执行要求
1. 直接修改文件，不要只给建议或方案
2. 所有代码改动必须在项目目录 ${PROJECT_DIR} 内
3. 完成后列出所有修改/新增/删除的文件清单
4. 如果有测试，跑一遍测试并报告结果
5. 如果遇到无法解决的阻塞，明确说明原因

## 输出格式
完成后请输出：
\`\`\`
=== 修改文件清单 ===
[新增] 文件路径 — 说明
[修改] 文件路径 — 说明
[删除] 文件路径 — 说明

=== 测试结果 ===
{测试命令和输出}

=== 遗留问题 ===
{如有}
\`\`\`"

# ─── 写入任务锁 ───
echo $$ > "$STATE_DIR/lock.pid"
echo "{\"task_id\": \"$TASK_ID\", \"started_at\": \"$(date -Iseconds)\", \"pid\": $$}" > "$STATE_DIR/active_task.json"

# ─── 实际执行函数（前台和后台共用） ───
run_claude_code() {
  local OUTPUT_FILE="$STATE_DIR/${TASK_ID}_output.txt"
  local STDERR_FILE="$STATE_DIR/${TASK_ID}_stderr.txt"
  local CALL_START=$(date +%s)
  local CALL_TIME=$(date -Iseconds)

  # 启动后台监控
  "$SCRIPT_DIR/monitor_claude.sh" --project-dir "$PROJECT_DIR" --task-id "$TASK_ID" &
  local MONITOR_PID=$!

  # 实际调用 Claude Code
  # 关键：使用 --permission-mode auto 而不是 --dangerously-skip-permissions
  # 这样 Claude Code 自动批准已授权的操作，不会弹确认框
  set +e
  timeout "${TIMEOUT}s" "$CLAUDE_BIN" -p "$PROMPT" \
    --output-format text \
    --permission-mode auto \
    --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
    --cwd "$PROJECT_DIR" \
    > "$OUTPUT_FILE" 2>"$STDERR_FILE"
  local EXIT_CODE=$?
  set -e

  local CALL_END=$(date +%s)
  local DURATION=$((CALL_END - CALL_START))

  # 停止监控
  kill "$MONITOR_PID" 2>/dev/null || true

  # ─── 记录调用日志 ───
  local FILES_CHANGED=$(cd "$PROJECT_DIR" && git diff --name-only HEAD 2>/dev/null | wc -l || echo 0)
  local UNTRACKED=$(cd "$PROJECT_DIR" && git ls-files --others --exclude-standard 2>/dev/null | wc -l || echo 0)
  FILES_CHANGED=$((FILES_CHANGED + UNTRACKED))

  # 提取 Claude Code 会话 ID
  local CLAUDE_SESSION_DIR="$HOME/.claude/projects"
  local LATEST_SESSION=$(find "$CLAUDE_SESSION_DIR" -name "*.jsonl" -newer "$STATE_DIR/active_task.json" 2>/dev/null | head -1 || echo "unknown")

  cat >> "$CALL_LOG" <<LOGEOF
{"call_time":"$CALL_TIME","task_id":"$TASK_ID","duration_seconds":$DURATION,"exit_code":$EXIT_CODE,"success":$([ $EXIT_CODE -eq 0 ] && echo true || echo false),"files_changed":$FILES_CHANGED,"session_file":"$LATEST_SESSION","output_file":"$OUTPUT_FILE","mode":"$([ "$BACKGROUND" = true ] && echo background || echo foreground)"}
LOGEOF

  # ─── 清理任务锁 ───
  rm -f "$STATE_DIR/lock.pid"
  rm -f "$STATE_DIR/${TASK_ID}_bg.pid"

  # ─── 环境快照（后） ───
  "$SCRIPT_DIR/env_snapshot.sh" --after --project-dir "$PROJECT_DIR" --task-id "$TASK_ID" 2>/dev/null || true

  # ─── 写入完成标记 ───
  echo "{\"task_id\":\"$TASK_ID\",\"completed_at\":\"$(date -Iseconds)\",\"exit_code\":$EXIT_CODE,\"duration\":$DURATION,\"files_changed\":$FILES_CHANGED}" > "$STATE_DIR/${TASK_ID}_done.json"

  # ─── 超时/失败处理 ───
  if [[ $EXIT_CODE -eq 124 ]]; then
    echo "⏰ Claude Code 调用超时（${TIMEOUT}s）" >> "$STDERR_FILE"
    # 超时不等于全部失败 — 可能已完成大部分工作
    # 分析半成品状态
    echo "📊 分析超时后的半成品状态..."
    local TIMEOUT_CHANGES=$(cd "$PROJECT_DIR" && git diff --stat HEAD 2>/dev/null | tail -1 || echo "无法统计")
    echo "   变更统计: $TIMEOUT_CHANGES" >> "$STDERR_FILE"
    echo "{\"event\":\"timeout\",\"task_id\":\"$TASK_ID\",\"partial_changes\":\"$TIMEOUT_CHANGES\"}" >> "$STATE_DIR/${TASK_ID}_done.json"
    return 4
  elif [[ $EXIT_CODE -ne 0 ]]; then
    echo "❌ Claude Code 调用失败（退出码: $EXIT_CODE）" >> "$STDERR_FILE"
    return 3
  fi

  # ─── 写项目状态文件（持久化到项目目录） ───
  cat > "$PROJECT_DIR/.dev-delegate-status.md" <<STATUSEOF
# Dev-Delegate 项目状态
**最后更新**: $(date -Iseconds)
**最后任务**: $TASK_ID
**状态**: $([ $EXIT_CODE -eq 0 ] && echo "完成" || echo "异常")
**文件变动**: $FILES_CHANGED 个

## 调用记录
- 任务ID: $TASK_ID
- 耗时: ${DURATION}s
- 退出码: $EXIT_CODE
- Claude Code 会话: $LATEST_SESSION
STATUSEOF

  return 0
}

# ─── 后台模式 ───
if [[ "$BACKGROUND" == "true" ]]; then
  echo "🚀 后台模式启动..."
  echo "   项目目录: $PROJECT_DIR"
  echo "   任务ID: $TASK_ID"
  echo "   超时: ${TIMEOUT}s"

  # 在后台执行
  (
    run_claude_code
  ) &
  BG_PID=$!
  echo "$BG_PID" > "$STATE_DIR/${TASK_ID}_bg.pid"

  echo ""
  echo "✅ Claude Code 已在后台启动"
  echo "   后台 PID: $BG_PID"
  echo ""
  echo "📊 查看进度："
  echo "   $0 --status --task-id $TASK_ID"
  echo ""
  echo "📋 实时监控日志："
  echo "   tail -f $STATE_DIR/${TASK_ID}_monitor.log"
  echo ""
  echo "📄 完成后输出："
  echo "   cat $STATE_DIR/${TASK_ID}_output.txt"
  echo ""
  echo "🏁 完成标记（检查是否跑完）："
  echo "   cat $STATE_DIR/${TASK_ID}_done.json"
  echo ""
  echo "OpenClaw 现在可以继续做其他事情了。"

  exit 0
fi

# ─── 前台模式 ───
echo "🚀 前台模式，调用 Claude Code..."
echo "   项目目录: $PROJECT_DIR"
echo "   任务ID: $TASK_ID"
echo "   超时: ${TIMEOUT}s"

run_claude_code
EXIT_CODE=$?

OUTPUT_FILE="$STATE_DIR/${TASK_ID}_output.txt"

if [[ $EXIT_CODE -ne 0 ]]; then
  echo ""
  echo "❌ Claude Code 调用异常（退出码: $EXIT_CODE）"
  echo "   输出: $OUTPUT_FILE"
  echo "   错误: $STATE_DIR/${TASK_ID}_stderr.txt"
  exit $EXIT_CODE
fi

echo ""
echo "✅ Claude Code 调用完成"
echo "   输出: $OUTPUT_FILE"
echo ""
echo "📋 Claude Code 输出摘要："
echo "─────────────────────────"
tail -50 "$OUTPUT_FILE"
echo "─────────────────────────"
echo ""
echo "➡️  下一步：执行 verify_delivery.sh 验证产出"
