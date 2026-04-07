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

# 检查 python3 可用性
if ! command -v python3 &>/dev/null; then
  echo "❌ python3 不可用，delegate_to_claude.sh 无法执行"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR"

# 动态查找 claude 可执行文件（H-07: 不再硬编码 nvm 版本号）
if [[ -n "${CLAUDE_BIN:-}" ]] && [[ -x "$CLAUDE_BIN" ]]; then
  : # 用户显式指定且可执行
elif command -v claude &>/dev/null; then
  CLAUDE_BIN="$(command -v claude)"
else
  # fallback: 搜索常见位置
  for candidate in \
    "$HOME/.nvm/versions/node"/*/bin/claude \
    /usr/local/bin/claude \
    /usr/bin/claude; do
    if [[ -x "$candidate" ]]; then
      CLAUDE_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "${CLAUDE_BIN:-}" ]] || [[ ! -x "${CLAUDE_BIN:-}" ]]; then
  echo "❌ 找不到 claude 可执行文件。请设置 CLAUDE_BIN 环境变量"
  exit 1
fi

CALL_LOG="$STATE_DIR/call_log.jsonl"
CLI_CAPS_CACHE="$STATE_DIR/.cli_caps_cache"
DEFAULT_TIMEOUT=1800  # 30 分钟（大任务需要更多时间）

# ─── Claude CLI 版本与能力探测（缓存） ───
detect_cli_capabilities() {
  # 获取当前 CLI 版本
  local CLI_VERSION
  CLI_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo "unknown")

  # 检查缓存是否有效（版本未变）
  if [[ -f "$CLI_CAPS_CACHE" ]]; then
    local CACHED_VERSION
    CACHED_VERSION=$(head -1 "$CLI_CAPS_CACHE" 2>/dev/null || echo "")
    if [[ "$CACHED_VERSION" == "$CLI_VERSION" ]]; then
      # 缓存命中，直接加载
      return 0
    fi
  fi

  # 缓存失效或不存在，重新探测
  local HELP_OUTPUT
  HELP_OUTPUT=$("$CLAUDE_BIN" --help 2>&1 || true)

  local HAS_OUTPUT_FORMAT=false HAS_PERMISSION_MODE=false HAS_SKIP_PERMISSIONS=false
  local HAS_ALLOWED_TOOLS=false HAS_ADD_DIR=false HAS_CWD=false HAS_MAX_TURNS=false
  local HAS_MODEL=false HAS_VERBOSE=false

  echo "$HELP_OUTPUT" | grep -q '\-\-output-format' && HAS_OUTPUT_FORMAT=true
  echo "$HELP_OUTPUT" | grep -q '\-\-permission-mode' && HAS_PERMISSION_MODE=true
  echo "$HELP_OUTPUT" | grep -q '\-\-dangerously-skip-permissions' && HAS_SKIP_PERMISSIONS=true
  echo "$HELP_OUTPUT" | grep -qE '\-\-allowedTools|--allowed-tools' && HAS_ALLOWED_TOOLS=true
  echo "$HELP_OUTPUT" | grep -q '\-\-add-dir' && HAS_ADD_DIR=true
  echo "$HELP_OUTPUT" | grep -q '\-\-cwd' && HAS_CWD=true
  echo "$HELP_OUTPUT" | grep -q '\-\-max-turns' && HAS_MAX_TURNS=true
  echo "$HELP_OUTPUT" | grep -q '\-\-model' && HAS_MODEL=true
  echo "$HELP_OUTPUT" | grep -q '\-\-verbose' && HAS_VERBOSE=true

  # 写入缓存
  cat > "$CLI_CAPS_CACHE" <<CAPSEOF
${CLI_VERSION}
output_format=${HAS_OUTPUT_FORMAT}
permission_mode=${HAS_PERMISSION_MODE}
skip_permissions=${HAS_SKIP_PERMISSIONS}
allowed_tools=${HAS_ALLOWED_TOOLS}
add_dir=${HAS_ADD_DIR}
cwd=${HAS_CWD}
max_turns=${HAS_MAX_TURNS}
model=${HAS_MODEL}
verbose=${HAS_VERBOSE}
detected_at=$(date -Iseconds)
CAPSEOF

  echo "📋 CLI 能力探测完成（版本: ${CLI_VERSION}），已缓存"
}

# 从缓存读取能力值
cli_has() {
  local cap="$1"
  grep -q "^${cap}=true" "$CLI_CAPS_CACHE" 2>/dev/null
}

# 执行探测
detect_cli_capabilities

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

  # H-08 修复：完成标记优先于 PID 存活判断
  # bg.pid 对应外层子shell可能在 done.json 写入后仍短暂存活
  DONE_FILE="$STATE_DIR/${TASK_ID}_done.json"
  TASK_RUNNING=false

  if [[ -f "$DONE_FILE" ]]; then
    # done.json 存在即视为已完成，无论 PID 是否仍存活
    echo "📍 状态：已结束"
  else
    TASK_PID=""
    if [[ -f "$BG_PID_FILE" ]]; then
      TASK_PID=$(cat "$BG_PID_FILE")
    elif [[ -f "$STATE_DIR/lock.pid" ]]; then
      TASK_PID=$(cat "$STATE_DIR/lock.pid")
    fi

    if [[ -n "$TASK_PID" ]]; then
      if kill -0 "$TASK_PID" 2>/dev/null; then
        echo "📍 状态：运行中（PID: $TASK_PID）"
        TASK_RUNNING=true
      else
        echo "📍 状态：已结束"
      fi
    else
      echo "📍 状态：未启动或已结束"
    fi
  fi

  # 运行中才显示监控日志
  if [[ "$TASK_RUNNING" == "true" && -f "$MONITOR_LOG" ]]; then
    echo ""
    echo "📊 最近进度："
    tail -3 "$MONITOR_LOG"
  fi

  # 已结束才显示输出摘要（不重复显示监控+输出）
  if [[ "$TASK_RUNNING" == "false" && -f "$DONE_FILE" ]]; then
    echo ""
    echo "📋 完成信息："
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(f'  退出码: {d.get(\"exit_code\",\"?\")}, 耗时: {d.get(\"duration\",\"?\")}s, 文件变动: {d.get(\"files_changed\",\"?\")}')" < "$DONE_FILE" 2>/dev/null || cat "$DONE_FILE"
  elif [[ "$TASK_RUNNING" == "false" && -f "$OUTPUT_FILE" && -s "$OUTPUT_FILE" ]]; then
    echo ""
    echo "📋 输出摘要（最后 10 行）："
    tail -10 "$OUTPUT_FILE"
  fi

  exit 0
fi

# ─── 生成唯一 task_token ───
TASK_TOKEN="${TASK_ID}_$(date +%s)_$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

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

# ─── Git Checkpoint（非 git 项目降级为文件列表快照） ───
if cd "$PROJECT_DIR" && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  echo "📸 创建 Git 快照..."
  "$SCRIPT_DIR/checkpoint.sh" --create --project-dir "$PROJECT_DIR" --label "before_${TASK_ID}"
else
  echo "⚠️  非 git 项目，降级为文件列表快照"
  find "$PROJECT_DIR" -not -path '*/__pycache__/*' -not -path '*/node_modules/*' -type f \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn > "$STATE_DIR/${TASK_ID}_file_snapshot.txt"
  echo "   已保存文件快照（$(wc -l < "$STATE_DIR/${TASK_ID}_file_snapshot.txt") 个文件）"
fi

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

# ─── 写入任务锁（前台模式在此写入，后台模式在子shell内写入） ───
if [[ "$BACKGROUND" != "true" ]]; then
  echo $$ > "$STATE_DIR/lock.pid"
fi
echo "{\"task_id\": \"$TASK_ID\", \"task_token\": \"$TASK_TOKEN\", \"started_at\": \"$(date -Iseconds)\", \"pid\": $$, \"task_brief\": \"$TASK_BRIEF\", \"project_dir\": \"$PROJECT_DIR\"}" > "$STATE_DIR/active_task.json"

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
  # 使用缓存的 CLI 能力探测结果构建参数（不再每次调 --help）
  local -a CLAUDE_ARGS=(-p "$PROMPT")
  local -a DEGRADED=()  # 记录降级项

  # --output-format
  if cli_has "output_format"; then
    CLAUDE_ARGS+=(--output-format text)
  else
    DEGRADED+=("output_format")
  fi

  # --permission-mode auto（无确认框）
  if cli_has "permission_mode"; then
    CLAUDE_ARGS+=(--permission-mode auto)
  elif cli_has "skip_permissions"; then
    CLAUDE_ARGS+=(--dangerously-skip-permissions)
    DEGRADED+=("permission_mode→skip_permissions")
  else
    DEGRADED+=("permission_mode")
  fi

  # --allowedTools
  if cli_has "allowed_tools"; then
    CLAUDE_ARGS+=(--allowedTools "Read,Write,Edit,Bash,Grep,Glob")
  else
    DEGRADED+=("allowed_tools")
  fi

  # --add-dir（替代不存在的 --cwd，确保 Claude 能访问项目目录）
  if cli_has "add_dir"; then
    CLAUDE_ARGS+=(--add-dir "$PROJECT_DIR")
  elif cli_has "cwd"; then
    CLAUDE_ARGS+=(--cwd "$PROJECT_DIR")
    DEGRADED+=("add_dir→cwd")
  else
    DEGRADED+=("add_dir")
  fi

  # 记录降级信息
  if [[ ${#DEGRADED[@]} -gt 0 ]]; then
    echo "⚠️  CLI 参数降级: ${DEGRADED[*]}" >> "$STATE_DIR/${TASK_ID}_stderr.txt"
  fi

  # 记录实际使用的参数开关（不含 prompt 内容）
  printf "bin: %s\nargs:" "$CLAUDE_BIN" > "$STATE_DIR/${TASK_ID}_cli_args.txt"
  for arg in "${CLAUDE_ARGS[@]}"; do
    [[ "$arg" == "$PROMPT" ]] && continue
    printf " %s" "$arg"
  done >> "$STATE_DIR/${TASK_ID}_cli_args.txt"
  echo "" >> "$STATE_DIR/${TASK_ID}_cli_args.txt"

  set +e
  (cd "$PROJECT_DIR" && timeout "${TIMEOUT}s" "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}") \
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

  # 提取 Claude Code 会话 ID（按修改时间倒排，取调用期间内最新的 session 文件）
  local CLAUDE_SESSION_DIR="$HOME/.claude/projects"
  local LATEST_SESSION
  LATEST_SESSION=$(find "$CLAUDE_SESSION_DIR" -name "*.jsonl" \
    -newer "$STATE_DIR/active_task.json" \
    -newermt "$(date -d "@$CALL_START" -Iseconds 2>/dev/null || echo '1970-01-01')" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || echo "unknown")
  [[ -z "$LATEST_SESSION" ]] && LATEST_SESSION="unknown"

  cat >> "$CALL_LOG" <<LOGEOF
{"call_time":"$CALL_TIME","task_id":"$TASK_ID","task_token":"$TASK_TOKEN","duration_seconds":$DURATION,"exit_code":$EXIT_CODE,"success":$([ $EXIT_CODE -eq 0 ] && echo true || echo false),"files_changed":$FILES_CHANGED,"session_file":"$LATEST_SESSION","output_file":"$OUTPUT_FILE","mode":"$([ "$BACKGROUND" = true ] && echo background || echo foreground)"}
LOGEOF

  # ─── 清理任务锁 ───
  rm -f "$STATE_DIR/lock.pid"
  rm -f "$STATE_DIR/${TASK_ID}_bg.pid"

  # ─── 环境快照（后） ───
  "$SCRIPT_DIR/env_snapshot.sh" --after --project-dir "$PROJECT_DIR" --task-id "$TASK_ID" 2>/dev/null || true

  # ─── 超时/失败处理 + 写入完成标记 ───
  if [[ $EXIT_CODE -eq 124 ]]; then
    echo "⏰ Claude Code 调用超时（${TIMEOUT}s）" >> "$STDERR_FILE"
    echo "📊 分析超时后的半成品状态..."
    local TIMEOUT_CHANGES=$(cd "$PROJECT_DIR" && git diff --stat HEAD 2>/dev/null | tail -1 || echo "无法统计")
    echo "   变更统计: $TIMEOUT_CHANGES" >> "$STDERR_FILE"
    # H-05 修复：超时场景写入合并的单个 JSON 对象（不再用 >> 追加）
    echo "{\"task_id\":\"$TASK_ID\",\"task_token\":\"$TASK_TOKEN\",\"completed_at\":\"$(date -Iseconds)\",\"exit_code\":$EXIT_CODE,\"duration\":$DURATION,\"files_changed\":$FILES_CHANGED,\"event\":\"timeout\",\"partial_changes\":\"$TIMEOUT_CHANGES\"}" > "$STATE_DIR/${TASK_ID}_done.json"
    return 4
  else
    # 正常完成或失败，写入完成标记
    echo "{\"task_id\":\"$TASK_ID\",\"task_token\":\"$TASK_TOKEN\",\"completed_at\":\"$(date -Iseconds)\",\"exit_code\":$EXIT_CODE,\"duration\":$DURATION,\"files_changed\":$FILES_CHANGED}" > "$STATE_DIR/${TASK_ID}_done.json"
  fi

  if [[ $EXIT_CODE -ne 0 && $EXIT_CODE -ne 124 ]]; then
    echo "❌ Claude Code 调用失败（退出码: $EXIT_CODE）" >> "$STDERR_FILE"
    return 3
  fi

  # ─── 写项目状态文件（持久化到项目目录） ───
  cat > "$PROJECT_DIR/.dev-delegate-status.md" <<STATUSEOF
# Dev-Delegate 项目状态
**最后更新**: $(date -Iseconds)
**最后任务**: $TASK_ID
**任务令牌**: $TASK_TOKEN
**状态**: $([ $EXIT_CODE -eq 0 ] && echo "完成" || echo "异常")
**文件变动**: $FILES_CHANGED 个

## 调用记录
- 任务ID: $TASK_ID
- 任务令牌: $TASK_TOKEN
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

  # 在后台执行（H-02 修复：在子shell内用 $BASHPID 写入 lock.pid）
  # L-02 修复：trap 捕获错误并写入状态文件
  (
    trap 'echo "{\"task_id\":\"'"$TASK_ID"'\",\"task_token\":\"'"$TASK_TOKEN"'\",\"error\":\"subshell_crash\",\"exit_code\":\$?,\"time\":\"$(date -Iseconds)\"}" > "'"$STATE_DIR/${TASK_ID}_done.json"'"; rm -f "'"$STATE_DIR/lock.pid"'"' ERR
    echo "$BASHPID" > "$STATE_DIR/lock.pid"
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
