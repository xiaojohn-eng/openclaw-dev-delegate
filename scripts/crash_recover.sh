#!/usr/bin/env bash
# crash_recover.sh — Claude Code 崩溃后的断点续接
# 用途：分析半成品状态，决定保留/回滚，生成续接任务简报
#
# 用法：
#   ./crash_recover.sh \
#     --project-dir /root/my-project \
#     --task-id task_001 \
#     --original-brief /path/to/original_brief.md
#
# 退出码（M-07 修复：不同决策对应不同退出码）：
#   0 = KEEP（保留半成品，续接完成）
#   1 = ROLLBACK（建议回滚）
#   2 = RETRY（直接重试）
#   3 = KEEP_AND_FIX（保留但需修复）

set -uo pipefail

# 检查 python3 可用性
if ! command -v python3 &>/dev/null; then
  echo "❌ python3 不可用，crash_recover.sh 无法执行"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR"

PROJECT_DIR=""
TASK_ID=""
ORIGINAL_BRIEF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)     PROJECT_DIR="$2"; shift 2 ;;
    --task-id)         TASK_ID="$2"; shift 2 ;;
    --original-brief)  ORIGINAL_BRIEF="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$PROJECT_DIR" || -z "$TASK_ID" ]]; then
  echo "❌ 缺少 --project-dir 或 --task-id"
  exit 1
fi

OUTPUT_FILE="$STATE_DIR/${TASK_ID}_output.txt"
STDERR_FILE="$STATE_DIR/${TASK_ID}_stderr.txt"
RECOVER_REPORT="$STATE_DIR/${TASK_ID}_crash_report.md"
RESUME_BRIEF="$STATE_DIR/${TASK_ID}_resume_brief.md"
DECISION=""  # 决策结果

{
echo "# 崩溃恢复分析：${TASK_ID}"
echo "**时间**：$(date -Iseconds)"
echo ""

# ─── 1. 分析崩溃原因 ───
echo "## 1. 崩溃原因分析"

DONE_FILE="$STATE_DIR/${TASK_ID}_done.json"
EXIT_CODE="?"
DURATION="?"
if [[ -f "$DONE_FILE" ]]; then
  # 安全解析 JSON（通过 stdin，避免路径注入）
  EXIT_CODE=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('exit_code','?'))" < "$DONE_FILE" 2>/dev/null || echo "?")
  DURATION=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('duration','?'))" < "$DONE_FILE" 2>/dev/null || echo "?")
  echo "- 退出码: $EXIT_CODE"
  echo "- 运行时长: ${DURATION}s"

  case "$EXIT_CODE" in
    124) echo "- 原因: **超时** — Claude Code 在规定时间内未完成" ;;
    137) echo "- 原因: **被 kill** — 进程被强制终止（SIGKILL）" ;;
    143) echo "- 原因: **优雅退出** — 进程收到 SIGTERM" ;;
    1)   echo "- 原因: **一般错误** — Claude Code 执行中遇到错误" ;;
    *)   echo "- 原因: 退出码 $EXIT_CODE" ;;
  esac
else
  echo "- ⚠️ 无完成标记文件，可能是进程被意外终止"
fi

if [[ -f "$STDERR_FILE" && -s "$STDERR_FILE" ]]; then
  echo ""
  echo "错误输出（最后 10 行）："
  echo '```'
  tail -10 "$STDERR_FILE"
  echo '```'
fi
echo ""

# ─── 2. 分析半成品状态 ───
echo "## 2. 半成品状态评估"

cd "$PROJECT_DIR" 2>/dev/null || { echo "❌ 无法进入项目目录"; exit 1; }

# 找到最近的 checkpoint（仅搜索当前分支，H-03 同理）
CHECKPOINT_HASH=""
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  CHECKPOINT_HASH=$(git log --oneline | grep "checkpoint:.*before_${TASK_ID}" | head -1 | awk '{print $1}')
fi

if [[ -n "$CHECKPOINT_HASH" ]]; then
  # 计算 checkpoint 以来的变更
  CHANGED=$(git diff --name-only "$CHECKPOINT_HASH" 2>/dev/null || true)
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
  ALL_NEW="$CHANGED"$'\n'"$UNTRACKED"
  ALL_NEW=$(echo "$ALL_NEW" | sed '/^$/d' | sort -u)
  NEW_COUNT=$(echo "$ALL_NEW" | sed '/^$/d' | wc -l)

  echo "- 自 checkpoint 以来变更了 **${NEW_COUNT}** 个文件"
  if [[ $NEW_COUNT -gt 0 ]]; then
    echo ""
    echo "变更文件列表："
    echo "$ALL_NEW" | sed 's/^/  - /'
  fi
else
  echo "- ⚠️ 未找到对应的 checkpoint，无法精确对比"
  NEW_COUNT=0
fi
echo ""

# ─── 3. 跑测试看半成品是否可用 ───
echo "## 3. 半成品可用性测试"

TEST_PASSED=false
if [[ -f "pyproject.toml" || -d "tests" ]]; then
  set +e
  TEST_OUTPUT=$(python3 -m pytest --tb=line -q 2>&1)
  TEST_EXIT=$?
  set -e
  echo '```'
  echo "$TEST_OUTPUT" | tail -15
  echo '```'
  if [[ $TEST_EXIT -eq 0 ]]; then
    echo "- ✅ 测试通过 — 半成品状态可用"
    TEST_PASSED=true
  elif [[ $TEST_EXIT -eq 5 ]]; then
    echo "- ⚠️ 无测试用例"
  else
    echo "- ❌ 测试失败"
  fi
elif [[ -f "package.json" ]]; then
  set +e
  TEST_OUTPUT=$(npm test 2>&1)
  TEST_EXIT=$?
  set -e
  echo '```'
  echo "$TEST_OUTPUT" | tail -15
  echo '```'
  [[ $TEST_EXIT -eq 0 ]] && TEST_PASSED=true
fi
echo ""

# ─── 4. 决策建议（H-04 修复：严格按 SKILL.md 决策矩阵实现） ───
# | 测试通过 | 文件变更数 | 决策             |
# |---------|----------|------------------|
# | ✅ 通过 | >3 个    | KEEP 保留，续接   |
# | ❌ 失败 | >3 个    | KEEP_AND_FIX     |
# | ❌ 失败 | ≤3 个   | ROLLBACK 回滚     |
# | 任意    | 0 个     | RETRY 直接重试    |
echo "## 4. 恢复建议"

if [[ $NEW_COUNT -eq 0 ]]; then
  # 情况 4: 无变更 → 直接重试
  DECISION="RETRY"
  echo "### 建议：直接重试"
  echo ""
  echo "理由："
  echo "- Claude Code 几乎没有产出任何文件变更"
  echo "- 可能是启动阶段就失败了"
  echo "- 用原始任务简报重新调用即可"
elif [[ "$TEST_PASSED" == "true" && $NEW_COUNT -gt 3 ]]; then
  # 情况 1: 测试通过 + 变更 >3 → 保留
  DECISION="KEEP"
  echo "### 建议：保留半成品，续接完成"
  echo ""
  echo "理由："
  echo "- 已有 ${NEW_COUNT} 个文件变更"
  echo "- 测试可以通过"
  echo "- 回滚会丢失大量已完成的工作"
elif [[ "$TEST_PASSED" == "true" && $NEW_COUNT -le 3 ]]; then
  # 测试通过但变更少 → 也保留（测试通过说明代码没问题）
  DECISION="KEEP"
  echo "### 建议：保留半成品，续接完成"
  echo ""
  echo "理由："
  echo "- 有 ${NEW_COUNT} 个文件变更"
  echo "- 测试可以通过，代码状态正常"
  echo "- 续接完成剩余部分"
elif [[ "$TEST_PASSED" == "false" && $NEW_COUNT -gt 3 ]]; then
  # 情况 2: 测试失败 + 变更 >3 → 保留但修复
  DECISION="KEEP_AND_FIX"
  echo "### 建议：保留半成品，但需要修复"
  echo ""
  echo "理由："
  echo "- 有 ${NEW_COUNT} 个文件变更，不宜全部丢弃"
  echo "- 但测试不通过，说明有未完成或有错误的部分"
  echo "- 建议生成续接任务简报，让 Claude Code 修复"
else
  # 情况 3: 测试失败 + 变更 ≤3 → 回滚
  DECISION="ROLLBACK"
  echo "### 建议：回滚到 checkpoint"
  echo ""
  echo "理由："
  echo "- 变更量少（${NEW_COUNT} 个文件）且测试不通过"
  echo "- 不值得保留"
  if [[ -n "$CHECKPOINT_HASH" ]]; then
    echo ""
    echo "回滚命令："
    echo '```bash'
    echo "$SCRIPT_DIR/checkpoint.sh --rollback --project-dir $PROJECT_DIR"
    echo '```'
  fi
fi
echo ""

# ─── 5. 生成续接任务简报 ───
if [[ "$DECISION" == "KEEP" || "$DECISION" == "KEEP_AND_FIX" ]]; then
  echo "## 5. 续接任务简报已生成"
  echo "路径: $RESUME_BRIEF"

  # 从 Claude Code 输出中提取已完成的部分
  PARTIAL_OUTPUT=""
  if [[ -f "$OUTPUT_FILE" && -s "$OUTPUT_FILE" ]]; then
    PARTIAL_OUTPUT=$(tail -100 "$OUTPUT_FILE")
  fi

  # 原始任务简报内容
  ORIG_CONTENT=""
  if [[ -n "$ORIGINAL_BRIEF" && -f "$ORIGINAL_BRIEF" ]]; then
    ORIG_CONTENT=$(cat "$ORIGINAL_BRIEF")
  fi

  cat > "$RESUME_BRIEF" <<BRIEFEOF
# 任务简报：${TASK_ID}_resume（断点续接）

## 1. 背景
这是任务 ${TASK_ID} 的断点续接。上一次 Claude Code 执行中途异常退出（退出码: ${EXIT_CODE:-?}），
当前项目处于半成品状态：有 ${NEW_COUNT} 个文件已被修改，$([ "$TEST_PASSED" = true ] && echo "测试可以通过" || echo "测试不通过")。

## 2. 目标
在已有半成品基础上，完成剩余未完成的部分。

验收标准：
- [ ] 原始任务简报中的所有验收标准全部满足
- [ ] 全部测试通过
- [ ] 无 import 错误，项目可正常启动

## 3. 约束
- 不要重写已经正常工作的模块
- 只修复/补全未完成的部分
- 保留已有的代码风格和架构决策

## 4. 输入
| 文件路径 | 作用 |
|---------|------|
| 项目目录下所有文件 | 半成品状态，需要先 read 理解当前进度 |

### 上次 Claude Code 的部分输出（如有）
\`\`\`
${PARTIAL_OUTPUT:-无输出}
\`\`\`

### 原始任务要求
${ORIG_CONTENT:-见原始任务简报}

## 5. 输出
完成原始任务简报中要求的所有输出文件。

## 6. 依赖
与原始任务相同。注意：上次执行可能已安装了部分依赖。
BRIEFEOF

fi

} 2>&1 | tee "$RECOVER_REPORT"

echo ""
echo "📄 崩溃分析报告: $RECOVER_REPORT"
[[ -f "$RESUME_BRIEF" ]] && echo "📋 续接任务简报: $RESUME_BRIEF"

# M-07 修复：根据决策返回不同退出码
case "$DECISION" in
  KEEP)         exit 0 ;;
  ROLLBACK)     exit 1 ;;
  RETRY)        exit 2 ;;
  KEEP_AND_FIX) exit 3 ;;
  *)            exit 1 ;;
esac
