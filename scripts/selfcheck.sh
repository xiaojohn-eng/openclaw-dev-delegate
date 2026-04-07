#!/usr/bin/env bash
# selfcheck.sh — dev-delegate 版本与依赖自检
# 用途：检查运行环境是否满足 dev-delegate 所有依赖，报告版本信息
#
# 用法：
#   ./selfcheck.sh              # 人类可读输出
#   ./selfcheck.sh --json       # 机器可读 JSON 输出

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
JSON_OUTPUT=false

show_help() {
  cat <<'HELPEOF'
selfcheck.sh — dev-delegate 版本与依赖自检

用法：
  ./selfcheck.sh              # 人类可读输出
  ./selfcheck.sh --json       # 机器可读 JSON 输出

参数：
  --json         以 JSON 格式输出
  -h, --help     显示此帮助信息

检查项：
  - bash 版本（≥4.0）
  - python3 可用性与版本
  - git 可用性与版本
  - claude CLI 可用性与版本
  - 所有脚本可执行权限
  - state 目录可写
HELPEOF
  exit 0
}

case "${1:-}" in
  -h|--help) show_help ;;
  --json) JSON_OUTPUT=true ;;
esac

# ─── 收集检查结果 ───
CHECKS=()
PASS=0
FAIL=0
WARN=0

check_pass() {
  CHECKS+=("PASS|$1|$2")
  ((PASS++)) || true
}
check_fail() {
  CHECKS+=("FAIL|$1|$2")
  ((FAIL++)) || true
}
check_warn() {
  CHECKS+=("WARN|$1|$2")
  ((WARN++)) || true
}

# ─── 1. bash 版本 ───
BASH_VER="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
if [[ ${BASH_VERSINFO[0]} -ge 4 ]]; then
  check_pass "bash" "v${BASH_VER}"
else
  check_fail "bash" "v${BASH_VER}（需要 ≥4.0）"
fi

# ─── 2. python3 ───
if command -v python3 &>/dev/null; then
  PY_VER=$(python3 --version 2>&1 | awk '{print $2}')
  check_pass "python3" "v${PY_VER}"
else
  check_fail "python3" "未安装"
fi

# ─── 3. git ───
if command -v git &>/dev/null; then
  GIT_VER=$(git --version 2>&1 | awk '{print $3}')
  check_pass "git" "v${GIT_VER}"
else
  check_fail "git" "未安装"
fi

# ─── 4. claude CLI ───
CLAUDE_VER="未安装"
if [[ -n "${CLAUDE_BIN:-}" ]] && [[ -x "$CLAUDE_BIN" ]]; then
  CLAUDE_VER=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  check_pass "claude" "${CLAUDE_VER}"
elif command -v claude &>/dev/null; then
  CLAUDE_VER=$(claude --version 2>/dev/null | head -1 || echo "unknown")
  check_pass "claude" "${CLAUDE_VER}"
else
  check_warn "claude" "未安装（委托功能不可用，但不影响自检和回归测试）"
fi

# ─── 5. 脚本可执行权限 ───
SCRIPT_ISSUES=0
for script in "$SCRIPT_DIR"/*.sh; do
  if [[ ! -x "$script" ]]; then
    ((SCRIPT_ISSUES++)) || true
  fi
done
if [[ $SCRIPT_ISSUES -eq 0 ]]; then
  SCRIPT_COUNT=$(ls "$SCRIPT_DIR"/*.sh 2>/dev/null | wc -l)
  check_pass "scripts_executable" "全部 ${SCRIPT_COUNT} 个脚本可执行"
else
  check_fail "scripts_executable" "${SCRIPT_ISSUES} 个脚本缺少可执行权限"
fi

# ─── 6. state 目录可写 ───
STATE_DIR="$SKILL_DIR/state"
mkdir -p "$STATE_DIR" 2>/dev/null
if [[ -w "$STATE_DIR" ]]; then
  check_pass "state_dir" "$STATE_DIR 可写"
else
  check_fail "state_dir" "$STATE_DIR 不可写"
fi

# ─── 7. SKILL.md 存在 ───
if [[ -f "$SKILL_DIR/SKILL.md" ]]; then
  SKILL_SIZE=$(stat -c%s "$SKILL_DIR/SKILL.md" 2>/dev/null || stat -f%z "$SKILL_DIR/SKILL.md" 2>/dev/null || echo 0)
  check_pass "skill_md" "SKILL.md 存在 (${SKILL_SIZE} bytes)"
else
  check_warn "skill_md" "SKILL.md 不存在"
fi

# ─── 8. 最近 git commit ───
if cd "$SKILL_DIR" && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  LAST_COMMIT=$(git log --oneline -1 2>/dev/null || echo "unknown")
  check_pass "git_repo" "最近提交: $LAST_COMMIT"
else
  check_warn "git_repo" "非 git 仓库"
fi

# ─── 输出 ───
if [[ "$JSON_OUTPUT" == "true" ]]; then
  python3 -c "
import json, sys

checks = []
for line in sys.argv[1:]:
    parts = line.split('|', 2)
    checks.append({
        'result': parts[0],
        'name': parts[1],
        'detail': parts[2]
    })

result = {
    'tool': 'dev-delegate',
    'selfcheck_at': '$(date -Iseconds)',
    'summary': {'pass': $PASS, 'fail': $FAIL, 'warn': $WARN},
    'ok': $FAIL == 0,
    'checks': checks
}
print(json.dumps(result, ensure_ascii=False, indent=2))
" "${CHECKS[@]}"
else
  echo "=== dev-delegate 自检 ==="
  echo "时间: $(date -Iseconds)"
  echo ""

  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r result name detail <<< "$entry"
    case "$result" in
      PASS) echo "  ✅ $name: $detail" ;;
      FAIL) echo "  ❌ $name: $detail" ;;
      WARN) echo "  ⚠️  $name: $detail" ;;
    esac
  done

  echo ""
  echo "─────────────────"
  echo "通过: $PASS | 失败: $FAIL | 警告: $WARN"

  if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "🔴 有 $FAIL 项依赖检查失败，部分功能可能不可用"
  else
    echo ""
    echo "🟢 环境就绪"
  fi
  echo "=== 自检完成 ==="
fi

[[ $FAIL -eq 0 ]]
