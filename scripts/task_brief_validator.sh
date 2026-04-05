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

BRIEF_FILE="${1:-}"

if [[ -z "$BRIEF_FILE" || ! -f "$BRIEF_FILE" ]]; then
  echo "❌ 用法: $0 <task_brief.md>"
  exit 1
fi

CONTENT=$(cat "$BRIEF_FILE")
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
  # 提取该 section 的内容（从 ## 标题到下一个 ## 或文件结尾）
  SECTION_CONTENT=$(python3 -c "
import re, sys

content = '''$( echo "$CONTENT" | sed "s/'/\\\\'/g" )'''

# 匹配 ## 背景 或 ### 背景 或 **背景** 等格式
pattern = r'(?:^#{1,4}\s*(?:\d+[\.\)]\s*)?$section|^\*\*$section\*\*)'
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
" 2>/dev/null || echo "")

  CHAR_COUNT=${#SECTION_CONTENT}

  if [[ $CHAR_COUNT -lt $MIN_CHARS ]]; then
    ((FAIL_COUNT++))
    if [[ $CHAR_COUNT -eq 0 ]]; then
      ISSUES="${ISSUES}\n  ❌ 「${section}」 — 缺失"
    else
      ISSUES="${ISSUES}\n  ❌ 「${section}」 — 内容过少（${CHAR_COUNT} 字 < ${MIN_CHARS} 字最低要求）"
    fi
  else
    ((PASS_COUNT++))
    echo "  ✅ 「${section}」 — ${CHAR_COUNT} 字"
  fi
done

echo ""

# 额外检查：文件路径
if echo "$CONTENT" | grep -qP '/\w+/\w+' 2>/dev/null; then
  echo "  ✅ 包含文件路径引用"
  ((PASS_COUNT++))
else
  echo "  ⚠️  未发现文件路径引用（建议在「输入」和「输出」中列出具体路径）"
fi

# 额外检查：验收标准
if echo "$CONTENT" | grep -qiP '验收|完成标准|done.when|acceptance' 2>/dev/null; then
  echo "  ✅ 包含验收标准描述"
  ((PASS_COUNT++))
else
  echo "  ⚠️  未发现明确的验收标准（建议在「目标」中量化）"
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
