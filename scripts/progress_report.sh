#!/usr/bin/env bash
# progress_report.sh — 证据链汇报生成
# 用途：生成结构化的阶段进度报告，供 OpenClaw 发给用户
#
# 用法：
#   ./progress_report.sh \
#     --project-dir /root/my-project \
#     --task-id task_001 \
#     --phase "阶段名称" \
#     [--next-phase "下一阶段"]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"

PROJECT_DIR=""
TASK_ID=""
PHASE=""
NEXT_PHASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --task-id)     TASK_ID="$2"; shift 2 ;;
    --phase)       PHASE="$2"; shift 2 ;;
    --next-phase)  NEXT_PHASE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$PROJECT_DIR" || -z "$TASK_ID" ]]; then
  echo "❌ 缺少必要参数"
  exit 1
fi

REPORT_FILE="$STATE_DIR/${TASK_ID}_phase_report.md"
VERIFY_REPORT="$STATE_DIR/${TASK_ID}_verify_report.md"
MONITOR_LOG="$STATE_DIR/${TASK_ID}_monitor.log"
CALL_LOG="$STATE_DIR/call_log.jsonl"
OUTPUT_FILE="$STATE_DIR/${TASK_ID}_output.txt"

{

echo "# 阶段完成汇报"
echo ""
echo "| 项目 | 值 |"
echo "|------|-----|"
echo "| **任务ID** | $TASK_ID |"
echo "| **阶段** | ${PHASE:-进行中} |"
echo "| **项目路径** | $PROJECT_DIR |"
echo "| **汇报时间** | $(date '+%Y-%m-%d %H:%M:%S') |"
echo ""

# ─── Claude Code 调用证据 ───
echo "## 1. Claude Code 调用证据"

if [[ -f "$CALL_LOG" ]]; then
  TASK_LOG=$(grep "\"$TASK_ID\"" "$CALL_LOG" | tail -1)
  if [[ -n "$TASK_LOG" ]]; then
    DURATION=$(echo "$TASK_LOG" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('duration_seconds','?'))" 2>/dev/null || echo "?")
    SUCCESS=$(echo "$TASK_LOG" | python3 -c "import sys,json; print('✅ 成功' if json.loads(sys.stdin.read()).get('success') else '❌ 失败')" 2>/dev/null || echo "?")
    FILES_CHANGED=$(echo "$TASK_LOG" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('files_changed',0))" 2>/dev/null || echo "?")

    echo "- **调用结果**: $SUCCESS"
    echo "- **耗时**: ${DURATION}s"
    echo "- **文件变动数**: $FILES_CHANGED"
  else
    echo "- ⚠️ 调用日志中无此任务记录"
  fi
else
  echo "- ⚠️ 无调用日志"
fi
echo ""

# ─── 文件变更清单 ───
echo "## 2. 文件变更清单"

cd "$PROJECT_DIR" 2>/dev/null || true

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  # 从最近的 checkpoint 计算 diff
  CHECKPOINT_HASH=$(git log --oneline | grep "checkpoint:" | head -1 | awk '{print $1}')
  if [[ -n "$CHECKPOINT_HASH" ]]; then
    DIFF_OUTPUT=$(git diff --stat "$CHECKPOINT_HASH" HEAD 2>/dev/null || echo "")
    DIFF_FILES=$(git diff --name-status "$CHECKPOINT_HASH" HEAD 2>/dev/null || echo "")
  else
    DIFF_OUTPUT=$(git diff --stat HEAD 2>/dev/null || echo "")
    DIFF_FILES=$(git diff --name-status HEAD 2>/dev/null || echo "")
  fi

  # 加上未跟踪文件
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")

  if [[ -n "$DIFF_FILES" || -n "$UNTRACKED" ]]; then
    echo "| 状态 | 文件 |"
    echo "|------|------|"
    echo "$DIFF_FILES" | while IFS=$'\t' read -r status filepath; do
      [[ -z "$filepath" ]] && continue
      case "$status" in
        A) echo "| 新增 | \`$filepath\` |" ;;
        M) echo "| 修改 | \`$filepath\` |" ;;
        D) echo "| 删除 | \`$filepath\` |" ;;
        *) echo "| $status | \`$filepath\` |" ;;
      esac
    done
    echo "$UNTRACKED" | while IFS= read -r filepath; do
      [[ -z "$filepath" ]] && continue
      echo "| 新增(未跟踪) | \`$filepath\` |"
    done
  else
    echo "无文件变更"
  fi
else
  echo "项目非 git 仓库，列出最近修改的文件："
  find "$PROJECT_DIR" -not -path '*/.git/*' -not -path '*/__pycache__/*' -type f -mmin -60 2>/dev/null | head -20 | while IFS= read -r f; do
    echo "- \`$(echo "$f" | sed "s|$PROJECT_DIR/||")\`"
  done
fi
echo ""

# ─── 验证结果 ───
echo "## 3. 验证结果"

if [[ -f "$VERIFY_REPORT" ]]; then
  # 提取验证汇总
  grep -A5 "验证汇总\|验证结论" "$VERIFY_REPORT" 2>/dev/null || echo "（无法提取验证汇总）"
else
  echo "⚠️ 尚未执行 verify_delivery.sh"
fi
echo ""

# ─── 监控日志摘要 ───
echo "## 4. 开发过程监控"

if [[ -f "$MONITOR_LOG" ]]; then
  echo "最近 10 条监控记录："
  echo "\`\`\`"
  tail -10 "$MONITOR_LOG"
  echo "\`\`\`"
else
  echo "无监控日志"
fi
echo ""

# ─── 下一步 ───
echo "## 5. 下一步"

if [[ -n "$NEXT_PHASE" ]]; then
  echo "- **下一阶段**: $NEXT_PHASE"
else
  echo "- 等待用户指示"
fi
echo ""

# ─── 需用户决策的事项 ───
echo "## 6. 需用户决策的事项"
echo "- 无 / 有（如有请在此填写）"

} 2>&1 | tee "$REPORT_FILE"

echo ""
echo "📄 报告已保存: $REPORT_FILE"
