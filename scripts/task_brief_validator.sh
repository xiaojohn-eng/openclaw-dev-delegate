#!/usr/bin/env bash
# task_brief_validator.sh — 任务简报质量校验
# 用途：确保发给 Claude Code 的任务简报质量合格，减少无效调用
#
# 用法：
#   ./task_brief_validator.sh /path/to/task_brief.md
#
# 退出码：
#   0 = 合格
#   1 = 不合格（附带缺失项）

set -uo pipefail

# 检查 python3 可用性
if ! command -v python3 &>/dev/null; then
  echo "❌ python3 不可用，task_brief_validator.sh 无法执行"
  exit 1
fi

show_help() {
  cat <<'HELPEOF'
task_brief_validator.sh — 任务简报质量校验

用法：
  ./task_brief_validator.sh <task_brief.md>

参数：
  <task_brief.md>    待校验的任务简报文件
  -h, --help         显示此帮助信息

退出码：
  0 = 合格
  1 = 不合格（附带缺失项）
HELPEOF
  exit 0
}

case "${1:-}" in
  -h|--help) show_help ;;
esac

BRIEF_FILE="${1:-}"

if [[ -z "$BRIEF_FILE" || ! -f "$BRIEF_FILE" ]]; then
  echo "❌ 用法: $0 <task_brief.md>"
  exit 1
fi

MIN_CHARS=20  # 每个字段至少 20 个字符

REQUIRED_SECTIONS=(
  "背景"
  "目标"
  "约束"
  "输入"
  "输出"
  "依赖"
)

PASS_COUNT=0
FAIL_COUNT=0
ISSUES=""

echo "🔍 校验任务简报: $BRIEF_FILE"
echo ""

for section in "${REQUIRED_SECTIONS[@]}"; do
  # 安全方式：通过 stdin 传递文件内容，通过 sys.argv 传递 section 名
  SECTION_CONTENT=$(python3 -c "
import re, sys

content = sys.stdin.read()
section = sys.argv[1]

# 匹配 ## 背景 或 ### 背景 或 **背景** 等格式
pattern = r'(?:^#{1,4}\s*(?:\d+[\.\)]\s*)?' + re.escape(section) + r'|^\*\*' + re.escape(section) + r'\*\*)'
matches = list(re.finditer(pattern, content, re.MULTILINE))

if not matches:
    print('')
    sys.exit(0)

start = matches[0].end()
# 找下一个同级标题
next_header = re.search(r'^#{1,4}\s|\*\*[^*]+\*\*', content[start:], re.MULTILINE)
if next_header:
    end = start + next_header.start()
else:
    end = len(content)

section_text = content[start:end].strip()
print(section_text)
" "$section" < "$BRIEF_FILE" 2>/dev/null || echo "")

  CHAR_COUNT=${#SECTION_CONTENT}

  if [[ $CHAR_COUNT -lt $MIN_CHARS ]]; then
    ((FAIL_COUNT++)) || true
    if [[ $CHAR_COUNT -eq 0 ]]; then
      ISSUES="${ISSUES}\n  ❌ 「${section}」 — 缺失"
    else
      ISSUES="${ISSUES}\n  ❌ 「${section}」 — 内容过少（${CHAR_COUNT} 字 < ${MIN_CHARS} 字最低要求）"
    fi
  else
    ((PASS_COUNT++)) || true
    echo "  ✅ 「${section}」 — ${CHAR_COUNT} 字"
  fi
done

echo ""

# 额外检查：文件路径（使用 grep -E 替代 grep -P 以提高兼容性）
if grep -qE '/[a-zA-Z0-9_]+/[a-zA-Z0-9_]+' "$BRIEF_FILE" 2>/dev/null; then
  echo "  ✅ 包含文件路径引用"
  ((PASS_COUNT++)) || true
else
  echo "  ⚠️  未发现文件路径引用（建议在「输入」和「输出」中列出具体路径）"
fi

# 额外检查：验收标准
if grep -qiE '验收|完成标准|done.when|acceptance' "$BRIEF_FILE" 2>/dev/null; then
  echo "  ✅ 包含验收标准描述"
  ((PASS_COUNT++)) || true
else
  echo "  ⚠️  未发现明确的验收标准（建议在「目标」中量化）"
fi

# 额外检查：自动验收命令（可选加分项）
if grep -qE '验收命令|```bash' "$BRIEF_FILE" 2>/dev/null; then
  echo "  ✅ 包含自动验收命令"
  ((PASS_COUNT++)) || true
else
  echo "  ⚠️  未包含自动验收命令（建议添加，verify_delivery.sh 会自动执行）"
fi

echo ""
echo "─────────────────"

TOTAL=$((PASS_COUNT + FAIL_COUNT))

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "🟢 任务简报质量：合格（${PASS_COUNT}/${TOTAL} 通过）"
  echo "   可以发起 Claude Code 调用"
  exit 0
else
  echo "🔴 任务简报质量：不合格（${FAIL_COUNT} 项缺失）"
  echo -e "$ISSUES"
  echo ""
  echo "请补全以上缺失项后重新提交。模板参见："
  echo "  $(dirname "$0")/../templates/task_brief.md"
  exit 1
fi
