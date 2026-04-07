#!/usr/bin/env bash
# verify_delivery.sh — 产出验证脚本
# 用途：验证 Claude Code 的产出是否真实存在、测试是否通过
#
# 用法：
#   ./verify_delivery.sh \
#     --project-dir /root/my-project \
#     --task-id task_001 \
#     [--claimed-files file1.py,file2.py]  # 可选：声称修改的文件
#     [--test-cmd "python3 -m pytest"]      # 可选：测试命令
#
# 退出码：
#   0 = 全部验证通过
#   1 = 有验证项失败

set -uo pipefail

# 检查 python3 可用性
if ! command -v python3 &>/dev/null; then
  echo "❌ python3 不可用，verify_delivery.sh 无法执行"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR"

# ─── 参数解析 ───
PROJECT_DIR=""
TASK_ID=""
CLAIMED_FILES=""
TEST_CMD=""
ACCEPTANCE_CMDS=""  # 自动验收命令文件

show_help() {
  cat <<'HELPEOF'
verify_delivery.sh — 产出验证脚本

用法：
  ./verify_delivery.sh \
    --project-dir DIR --task-id ID \
    [--claimed-files file1.py,file2.py] \
    [--test-cmd "python3 -m pytest"] \
    [--acceptance-cmds FILE]

参数：
  --project-dir DIR         项目目录路径
  --task-id ID              任务唯一标识
  --claimed-files FILES     声称修改的文件（逗号分隔）
  --test-cmd CMD            测试命令
  --acceptance-cmds FILE    验收命令文件
  -h, --help                显示此帮助信息

退出码：
  0 = 全部验证通过
  1 = 有验证项失败
HELPEOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          show_help ;;
    --project-dir)      PROJECT_DIR="$2"; shift 2 ;;
    --task-id)          TASK_ID="$2"; shift 2 ;;
    --claimed-files)    CLAIMED_FILES="$2"; shift 2 ;;
    --test-cmd)         TEST_CMD="$2"; shift 2 ;;
    --acceptance-cmds)  ACCEPTANCE_CMDS="$2"; shift 2 ;;
    *) echo "❌ 未知参数: $1"; echo "使用 $0 --help 查看用法"; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_DIR" || -z "$TASK_ID" ]]; then
  echo "❌ 缺少 --project-dir 或 --task-id"
  exit 1
fi

REPORT_FILE="$STATE_DIR/${TASK_ID}_verify_report.md"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

log_pass() { echo "  ✅ $1"; ((PASS_COUNT++)) || true; }
log_fail() { echo "  ❌ $1"; ((FAIL_COUNT++)) || true; }
log_warn() { echo "  ⚠️  $1"; ((WARN_COUNT++)) || true; }

# ─── 测试/验收命令安全校验 ───
# 策略：先拒绝危险模式，再允许安全类别，未识别的放行但 log warning
validate_test_cmd() {
  local cmd="$1"

  # 第一关：拒绝明确危险的命令/模式
  if echo "$cmd" | grep -qE '(^rm |^dd |^mkfs|^chmod 777|^kill |^reboot|^shutdown|^systemctl|^mv /|^cp /dev)'; then
    return 1
  fi
  # 拒绝 shell 元字符（管道、链接、子shell、重定向到文件）
  if echo "$cmd" | grep -qE '(\|[^|]|;|&&|>\s*/|>>\s*/|\$\(|`.*`)'; then
    return 1
  fi

  # 第二关：已知安全类别直接放行
  local -a SAFE_PREFIXES=(
    # 测试框架
    "python3 -m pytest" "python -m pytest" "pytest" "python3 -m unittest"
    "uv run pytest" "uv run python" "poetry run pytest" "poetry run python"
    "npm test" "npm run test" "npx jest" "npx vitest" "npx mocha"
    "pnpm test" "pnpm run test" "pnpm exec " "pnpm lint" "pnpm run lint"
    "yarn test" "yarn run test" "yarn lint"
    "go test" "cargo test" "make test" "gradle test" "gradlew test"
    "./gradlew " "mvn test" "mvn verify" "dotnet test"
    "bundle exec rspec" "bundle exec rake" "php artisan test" "mix test"
    # 健康检查
    "curl -sf" "curl -s" "curl --fail" "curl http://127.0.0.1" "curl http://localhost"
    "wget -q"
    # 代码验证
    "python3 -c" "python -c" "node -e" "ruby -e" "go run"
    # 文件检查
    "ls " "cat " "test " "[ " "stat " "wc " "head " "tail " "grep " "diff "
    # 构建验证
    "make " "npm run " "yarn " "pnpm " "go build" "cargo build" "cargo check"
    "python3 -m " "pip " "pip3 " "uv pip " "uv run "
    # lint / type check
    "eslint" "tsc " "mypy " "flake8" "ruff " "golangci-lint" "clippy"
    "prettier " "biome " "deno lint" "deno check" "deno test"
    # 脚本执行
    "bash scripts/" "sh scripts/" "./scripts/" "bash test" "bash check"
  )
  for prefix in "${SAFE_PREFIXES[@]}"; do
    if [[ "$cmd" == "$prefix"* ]]; then
      return 0
    fi
  done

  # 第三关：未识别但不含危险模式 → 放行并 warning
  echo "  ⚠️  未识别的命令，放行执行: $cmd" >&2
  return 0
}

# ─── 将所有输出写入报告文件（不使用管道，避免子shell问题） ───
# 保存原始 stdout/stderr 的 fd（兼容无 tty 环境，如 OpenClaw 后台调用）
exec 3>&1 4>&2
exec > >(tee "$REPORT_FILE") 2>&1

# ─── 读取 task_token ───
TASK_TOKEN_VAL=""
DONE_FILE="$STATE_DIR/${TASK_ID}_done.json"
if [[ -f "$DONE_FILE" ]]; then
  TASK_TOKEN_VAL=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_token',''))" < "$DONE_FILE" 2>/dev/null || true)
fi
if [[ -z "$TASK_TOKEN_VAL" && -f "$STATE_DIR/active_task.json" ]]; then
  TASK_TOKEN_VAL=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
if d.get('task_id','') == sys.argv[1]:
    print(d.get('task_token',''))
else:
    print('')
" "$TASK_ID" < "$STATE_DIR/active_task.json" 2>/dev/null || true)
fi

echo "# 验证报告：${TASK_ID}"
echo "**时间**：$(date -Iseconds)"
echo "**项目**：${PROJECT_DIR}"
echo "**task_id**：${TASK_ID}"
echo "**task_token**：${TASK_TOKEN_VAL:-N/A}"
echo ""

# 收集分类文件列表（在汇总时输出）
_USER_ARTIFACTS=""
_INTERNAL_ARTIFACTS=""

# ─── 检查 1：Claude Code 会话是否真实存在 ───
echo "## 1. Claude Code 会话验证"

OUTPUT_FILE="$STATE_DIR/${TASK_ID}_output.txt"
if [[ -f "$OUTPUT_FILE" && -s "$OUTPUT_FILE" ]]; then
  OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || stat -f%z "$OUTPUT_FILE" 2>/dev/null || echo 0)
  log_pass "Claude Code 输出文件存在（${OUTPUT_SIZE} bytes）"
else
  log_fail "Claude Code 输出文件不存在或为空"
fi

# 检查调用日志
CALL_LOG="$STATE_DIR/call_log.jsonl"
if [[ -f "$CALL_LOG" ]]; then
  TASK_LOG=$(grep "\"$TASK_ID\"" "$CALL_LOG" | tail -1)
  if [[ -n "$TASK_LOG" ]]; then
    WAS_SUCCESS=$(echo "$TASK_LOG" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('success',False))" 2>/dev/null || echo "unknown")
    DURATION=$(echo "$TASK_LOG" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('duration_seconds',0))" 2>/dev/null || echo "?")
    if [[ "$WAS_SUCCESS" == "True" ]]; then
      log_pass "Claude Code 调用成功，耗时 ${DURATION}s"
    else
      log_fail "Claude Code 调用记录显示失败"
    fi
  else
    log_fail "调用日志中无此任务记录"
  fi
else
  log_fail "调用日志文件不存在"
fi
echo ""

# ─── 检查 2：Git 变更验证 ───
echo "## 2. Git 变更验证"

cd "$PROJECT_DIR" 2>/dev/null || { log_fail "无法进入项目目录"; }

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
  UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || true)
  ALL_CHANGES="$CHANGED_FILES"$'\n'"$UNTRACKED_FILES"
  ALL_CHANGES=$(echo "$ALL_CHANGES" | sed '/^$/d' | sort -u)
  CHANGE_COUNT=$(echo "$ALL_CHANGES" | sed '/^$/d' | wc -l)

  if [[ $CHANGE_COUNT -gt 0 ]]; then
    # 分类：用户交付文件 vs 技能辅助状态文件
    USER_FILES=""
    INTERNAL_FILES=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      case "$f" in
        .dev-delegate-status.md|.dev-delegate-*|state/*|*/state/*)
          INTERNAL_FILES="${INTERNAL_FILES}${f}"$'\n'
          ;;
        *)
          USER_FILES="${USER_FILES}${f}"$'\n'
          ;;
      esac
    done <<< "$ALL_CHANGES"

    USER_COUNT=$(echo "$USER_FILES" | sed '/^$/d' | wc -l)
    INTERNAL_COUNT=$(echo "$INTERNAL_FILES" | sed '/^$/d' | wc -l)

    log_pass "检测到 ${CHANGE_COUNT} 个文件变更（用户交付: ${USER_COUNT}, 辅助状态: ${INTERNAL_COUNT}）"

    if [[ $USER_COUNT -gt 0 ]]; then
      echo "  📦 用户交付文件："
      echo "$USER_FILES" | sed '/^$/d' | sed 's/^/    - /'
      _USER_ARTIFACTS=$(echo "$USER_FILES" | sed '/^$/d')
    fi
    if [[ $INTERNAL_COUNT -gt 0 ]]; then
      echo "  🔧 技能辅助状态文件（非交付产物）："
      echo "$INTERNAL_FILES" | sed '/^$/d' | sed 's/^/    - /'
      _INTERNAL_ARTIFACTS=$(echo "$INTERNAL_FILES" | sed '/^$/d')
    fi
  else
    log_warn "未检测到 git 变更（可能已被提交或无实际改动）"
  fi
else
  log_warn "项目不是 git 仓库，跳过 git 变更检查"
fi
echo ""

# ─── 检查 3：声称文件存在性 ───
echo "## 3. 文件存在性验证"

if [[ -n "$CLAIMED_FILES" ]]; then
  IFS=',' read -ra FILES <<< "$CLAIMED_FILES"
  for f in "${FILES[@]}"; do
    f=$(echo "$f" | xargs)  # trim
    if [[ -z "$f" ]]; then continue; fi
    FULL_PATH="$PROJECT_DIR/$f"
    # 也检查绝对路径
    [[ "$f" == /* ]] && FULL_PATH="$f"
    if [[ -f "$FULL_PATH" ]]; then
      FILE_SIZE=$(stat -c%s "$FULL_PATH" 2>/dev/null || stat -f%z "$FULL_PATH" 2>/dev/null || echo 0)
      log_pass "$f （${FILE_SIZE} bytes）"
    else
      log_fail "$f 不存在！"
    fi
  done
else
  # 如果没指定，从 Claude Code 输出中提取
  if [[ -f "$OUTPUT_FILE" ]]; then
    EXTRACTED=$(grep -oP '(?:\[新增\]|\[修改\]|\[删除\])\s+\S+' "$OUTPUT_FILE" 2>/dev/null | awk '{print $2}' || true)
    if [[ -n "$EXTRACTED" ]]; then
      echo "  从 Claude Code 输出中提取的文件列表："
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        FULL_PATH="$PROJECT_DIR/$f"
        [[ "$f" == /* ]] && FULL_PATH="$f"
        if [[ -f "$FULL_PATH" ]]; then
          log_pass "$f"
        else
          log_fail "$f 不存在！"
        fi
      done <<< "$EXTRACTED"
    else
      log_warn "无法从输出中提取文件列表，跳过"
    fi
  fi
fi
echo ""

# ─── 检查 4：最近文件修改时间 ───
echo "## 4. 最近修改的文件（30分钟内）"

RECENT_FILES=$(find "$PROJECT_DIR" \
  -not -path '*/.git/*' \
  -not -path '*/__pycache__/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/.dev-delegate/*' \
  -type f -mmin -30 2>/dev/null | head -30 || true)

if [[ -n "$RECENT_FILES" ]]; then
  RECENT_COUNT=$(echo "$RECENT_FILES" | wc -l)
  log_pass "发现 ${RECENT_COUNT} 个最近修改的文件"
  echo "$RECENT_FILES" | while IFS= read -r f; do
    REL=$(echo "$f" | sed "s|$PROJECT_DIR/||")
    MTIME=$(stat -c'%Y' "$f" 2>/dev/null || echo 0)
    MTIME_HR=$(date -d "@$MTIME" '+%H:%M:%S' 2>/dev/null || echo "?")
    echo "    - $REL ($MTIME_HR)"
  done
else
  log_warn "30分钟内无文件修改"
fi
echo ""

# ─── 检查 5：测试结果 ───
echo "## 5. 测试验证"

if [[ -n "$TEST_CMD" ]]; then
  if validate_test_cmd "$TEST_CMD"; then
    echo "  执行测试命令: $TEST_CMD"
    echo "  ─────────────"
    set +e
    TEST_OUTPUT=$(cd "$PROJECT_DIR" && eval "$TEST_CMD" 2>&1)
    TEST_EXIT=$?
    set -e
    echo "$TEST_OUTPUT" | tail -30 | sed 's/^/  /'
    echo "  ─────────────"
    if [[ $TEST_EXIT -eq 0 ]]; then
      log_pass "测试通过（退出码 0）"
    else
      log_fail "测试失败（退出码 $TEST_EXIT）"
    fi
  else
    log_fail "测试命令未通过白名单校验，拒绝执行: $TEST_CMD"
  fi
else
  # 自动检测测试框架
  cd "$PROJECT_DIR"
  if [[ -f "pyproject.toml" || -f "setup.py" || -d "tests" ]]; then
    echo "  检测到 Python 项目，尝试 pytest..."
    set +e
    TEST_OUTPUT=$(python3 -m pytest --tb=short -q 2>&1)
    TEST_EXIT=$?
    set -e
    echo "$TEST_OUTPUT" | tail -20 | sed 's/^/  /'
    if [[ $TEST_EXIT -eq 0 ]]; then
      log_pass "pytest 通过"
    elif [[ $TEST_EXIT -eq 5 ]]; then
      log_warn "pytest: 未找到测试用例"
    else
      log_fail "pytest 失败（退出码 $TEST_EXIT）"
    fi
  elif [[ -f "package.json" ]]; then
    echo "  检测到 Node 项目，尝试 npm test..."
    set +e
    TEST_OUTPUT=$(npm test 2>&1)
    TEST_EXIT=$?
    set -e
    echo "$TEST_OUTPUT" | tail -20 | sed 's/^/  /'
    if [[ $TEST_EXIT -eq 0 ]]; then
      log_pass "npm test 通过"
    else
      log_fail "npm test 失败（退出码 $TEST_EXIT）"
    fi
  else
    log_warn "未检测到测试框架，跳过自动测试"
  fi
fi
echo ""

# ─── 检查 6：自动验收命令 ───
echo "## 6. 自动验收命令"

if [[ -n "$ACCEPTANCE_CMDS" && -f "$ACCEPTANCE_CMDS" ]]; then
  echo "  执行验收命令文件: $ACCEPTANCE_CMDS"
  while IFS= read -r cmd; do
    cmd=$(echo "$cmd" | xargs)
    [[ -z "$cmd" || "$cmd" == "#"* ]] && continue
    if validate_test_cmd "$cmd"; then
      echo "  > $cmd"
      set +e
      CMD_OUTPUT=$(cd "$PROJECT_DIR" && eval "$cmd" 2>&1)
      CMD_EXIT=$?
      set -e
      if [[ $CMD_EXIT -eq 0 ]]; then
        log_pass "验收通过: $cmd"
      else
        log_fail "验收失败: $cmd"
        echo "$CMD_OUTPUT" | tail -5 | sed 's/^/    /'
      fi
    else
      log_fail "验收命令未通过白名单校验: $cmd"
    fi
  done < "$ACCEPTANCE_CMDS"
else
  # 从 active_task.json 直接读取 task_brief 路径（不再 find 猜测）
  TASK_BRIEF_FILE=""
  if [[ -f "$STATE_DIR/active_task.json" ]]; then
    TASK_BRIEF_FILE=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('task_brief',''))" < "$STATE_DIR/active_task.json" 2>/dev/null || true)
  fi
  # fallback: 仍然尝试 find
  if [[ -z "$TASK_BRIEF_FILE" || ! -f "$TASK_BRIEF_FILE" ]]; then
    TASK_BRIEF_FILE=$(find "$STATE_DIR" -name "${TASK_ID}*.md" 2>/dev/null | head -1 || true)
  fi

  if [[ -n "$TASK_BRIEF_FILE" && -f "$TASK_BRIEF_FILE" ]]; then
    # 安全提取 bash 代码块中的验收命令（通过 stdin 传递文件内容，避免路径注入）
    EXTRACTED_CMDS=$(python3 -c "
import re, sys
content = sys.stdin.read()
# 找 '验收命令' 或 'acceptance' 后面的 bash 代码块
pattern = r'(?:验收命令|acceptance|验收标准.*?)\n+\`\`\`(?:bash)?\n(.*?)\`\`\`'
matches = re.findall(pattern, content, re.DOTALL | re.IGNORECASE)
for m in matches:
    for line in m.strip().split('\n'):
        line = line.strip()
        if line and not line.startswith('#'):
            print(line)
" < "$TASK_BRIEF_FILE" 2>/dev/null || true)

    if [[ -n "$EXTRACTED_CMDS" ]]; then
      echo "  从任务简报中提取到验收命令："
      while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        if validate_test_cmd "$cmd"; then
          echo "  > $cmd"
          set +e
          CMD_OUTPUT=$(cd "$PROJECT_DIR" && eval "$cmd" 2>&1)
          CMD_EXIT=$?
          set -e
          if [[ $CMD_EXIT -eq 0 ]]; then
            log_pass "验收通过: $cmd"
          else
            log_fail "验收失败: $cmd"
            echo "$CMD_OUTPUT" | tail -5 | sed 's/^/    /'
          fi
        else
          log_fail "验收命令未通过白名单校验: $cmd"
        fi
      done <<< "$EXTRACTED_CMDS"
    else
      log_warn "未找到自动验收命令（建议在任务简报中添加）"
    fi
  else
    log_warn "未找到任务简报，跳过自动验收"
  fi
fi
echo ""

# ─── 检查 7：环境变更 ───
echo "## 7. 环境变更检查"

ENV_DIFF_FILE="$STATE_DIR/${TASK_ID}_env_diff.md"
if [[ -f "$STATE_DIR/${TASK_ID}_env_before_pip.txt" && -f "$STATE_DIR/${TASK_ID}_env_after_pip.txt" ]]; then
  "$SCRIPT_DIR/env_snapshot.sh" --diff --task-id "$TASK_ID" 2>/dev/null | grep -E "新增的包|移除的包|端口|无变更|检测到环境变更" | sed 's/^/  /' || log_warn "环境对比失败"
else
  log_warn "缺少环境快照，跳过对比"
fi
echo ""

# ─── 汇总 ───
echo "## 验证汇总"
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo "| 结果 | 数量 |"
echo "|------|------|"
echo "| ✅ 通过 | $PASS_COUNT |"
echo "| ❌ 失败 | $FAIL_COUNT |"
echo "| ⚠️  警告 | $WARN_COUNT |"
echo ""

FINAL_VERDICT=$( [[ $FAIL_COUNT -eq 0 ]] && echo "PASS" || echo "FAIL" )

echo "## 结构化归档字段"
echo ""
echo "| 字段 | 值 |"
echo "|------|-----|"
echo "| task_id | ${TASK_ID} |"
echo "| task_token | ${TASK_TOKEN_VAL:-N/A} |"
echo "| final_verdict | ${FINAL_VERDICT} |"
echo "| pass_count | ${PASS_COUNT} |"
echo "| fail_count | ${FAIL_COUNT} |"
echo "| warn_count | ${WARN_COUNT} |"
echo "| verified_at | $(date -Iseconds) |"

if [[ -n "$_USER_ARTIFACTS" ]]; then
  echo ""
  echo "### user_artifacts"
  echo "$_USER_ARTIFACTS" | sed 's/^/- /'
fi

if [[ -n "$_INTERNAL_ARTIFACTS" ]]; then
  echo ""
  echo "### internal_artifacts"
  echo "$_INTERNAL_ARTIFACTS" | sed 's/^/- /'
fi

echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "### 🟢 验证结论：通过（${FINAL_VERDICT}）"
  echo "所有关键检查项通过，可以向用户汇报完成。"
else
  echo "### 🔴 验证结论：未通过（${FINAL_VERDICT}）"
  echo "有 $FAIL_COUNT 项关键检查失败，**不得声称任务完成**。"
  echo ""
  echo "### 失败反馈（供重新调用 Claude Code 时使用）"
  echo ""
  echo "OpenClaw 在重新调用 Claude Code 时，必须将以下内容作为上下文传入："
  echo ""
  echo '```markdown'
  echo "## 上次任务失败的具体原因"
  echo ""
  echo "### 失败的验证项"

  # 回溯整个报告，提取 ❌ 行（排除表格汇总行）
  grep "❌" "$REPORT_FILE" 2>/dev/null | grep -v "^|" | grep -v "验证结论" | while IFS= read -r line; do
    echo "- $(echo "$line" | sed 's/^[[:space:]]*//')"
  done

  echo ""
  echo "### 修复要求"
  echo "1. 只修复上面列出的失败项"
  echo "2. 不要重写已经正常工作的模块"
  echo "3. 修完后跑一遍完整测试确认"
  echo '```'
  echo ""
  echo "📋 失败反馈已包含在报告中，可直接作为续接任务简报的输入。"
fi

# 恢复原始 stdout/stderr（兼容无 tty 环境）
exec 1>&3 2>&4 3>&- 4>&-

echo ""
echo "📄 完整报告已保存到: $REPORT_FILE"

# 退出码（现在 FAIL_COUNT 在主进程中，不再是子shell）
if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
else
  exit 0
fi
