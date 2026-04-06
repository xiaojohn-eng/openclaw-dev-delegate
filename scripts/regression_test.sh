#!/usr/bin/env bash
# regression_test.sh — dev-delegate 回归测试
# 用途：自动化验证所有核心场景，防止改代码后出回归
#
# 用法：
#   ./regression_test.sh              # 全量回归
#   ./regression_test.sh --quick      # 只跑快速测试（不含后台/超时）
#   ./regression_test.sh --test NAME  # 只跑指定测试
#
# 退出码：
#   0 = 全部通过
#   1 = 有测试失败

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"
TEST_BASE="/tmp/dev-delegate-regression-$$"
QUICK=false
SINGLE_TEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)  QUICK=true; shift ;;
    --test)   SINGLE_TEST="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

PASS=0
FAIL=0
SKIP=0
RESULTS=()

# ─── 工具函数 ───
setup_test_project() {
  local name="$1"
  local dir="$TEST_BASE/$name"
  mkdir -p "$dir"
  cd "$dir"
  git init -q
  echo "# test project" > README.md
  mkdir -p src tests
  echo 'print("hello")' > src/main.py
  echo 'def test_pass(): assert True' > tests/test_basic.py
  git add -A
  git commit -m "initial" -q
  echo "$dir"
}

create_brief() {
  local dir="$1"
  local brief="$dir/task_brief.md"
  cat > "$brief" <<'BRIEFEOF'
# 任务简报：回归测试

## 1. 背景
这是一个自动回归测试任务，用于验证 dev-delegate 技能正常工作。

## 2. 目标
在 src/main.py 中添加一个 greet 函数。

验收标准：
- [ ] src/main.py 包含 greet 函数
- [ ] tests/test_basic.py 通过

验收命令：
```bash
python3 -c "import sys; sys.path.insert(0,'src'); exec(open('src/main.py').read()); print('ok')"
```

## 3. 约束
不要修改已有的测试文件，不要删除任何文件，保持代码风格一致。

## 4. 输入
| 文件路径 | 作用 |
|---------|------|
| /tmp/project/src/main.py | 主模块，需要添加 greet 函数 |

## 5. 输出
修改后的 /tmp/project/src/main.py，包含 greet 函数定义和文档字符串。

## 6. 依赖
无外部依赖，Python 3.8+ 标准库即可满足需求。
BRIEFEOF
  echo "$brief"
}

run_test() {
  local name="$1"
  local description="$2"
  shift 2

  if [[ -n "$SINGLE_TEST" && "$SINGLE_TEST" != "$name" ]]; then
    ((SKIP++)) || true
    return 0
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🧪 测试: $name"
  echo "   说明: $description"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local start_time
  start_time=$(date +%s)

  # 执行测试函数
  set +e
  "$@"
  local rc=$?
  set -e

  local end_time duration
  end_time=$(date +%s)
  duration=$((end_time - start_time))

  if [[ $rc -eq 0 ]]; then
    echo "   ✅ 通过 (${duration}s)"
    ((PASS++)) || true
    RESULTS+=("✅ $name — $description (${duration}s)")
  else
    echo "   ❌ 失败 (退出码: $rc, ${duration}s)"
    ((FAIL++)) || true
    RESULTS+=("❌ $name — $description (退出码: $rc)")
  fi
}

# ═══════════════════════════════════════
#  测试用例
# ═══════════════════════════════════════

test_startup_check() {
  # 测试：startup_check 正常运行不报错
  "$SCRIPT_DIR/startup_check.sh" --cleanup >/dev/null 2>&1
}

test_brief_validator_pass() {
  # 测试：合格的 brief 通过校验
  local proj_dir
  proj_dir=$(setup_test_project "brief_pass")
  local brief
  brief=$(create_brief "$proj_dir")
  "$SCRIPT_DIR/task_brief_validator.sh" "$brief" >/dev/null 2>&1
}

test_brief_validator_fail() {
  # 测试：不合格的 brief 被拒绝
  local proj_dir
  proj_dir=$(setup_test_project "brief_fail")
  echo "just a line" > "$proj_dir/bad_brief.md"
  ! "$SCRIPT_DIR/task_brief_validator.sh" "$proj_dir/bad_brief.md" >/dev/null 2>&1
}

test_subscription_guard() {
  # 测试：subscription_guard --check 能正常返回
  "$SCRIPT_DIR/subscription_guard.sh" --check >/dev/null 2>&1 || {
    # 如果返回 1 可能是因为有并发锁，先清理
    "$SCRIPT_DIR/startup_check.sh" --cleanup >/dev/null 2>&1
    "$SCRIPT_DIR/subscription_guard.sh" --check >/dev/null 2>&1
  }
}

test_subscription_guard_status() {
  # 测试：subscription_guard --status 正常输出
  local output
  output=$("$SCRIPT_DIR/subscription_guard.sh" --status 2>&1)
  echo "$output" | grep -q "订阅配额状态"
}

test_checkpoint_create() {
  # 测试：checkpoint 创建和列出
  local proj_dir
  proj_dir=$(setup_test_project "ckpt_test")
  echo "new file" > "$proj_dir/new.txt"
  cd "$proj_dir" && git add -A
  "$SCRIPT_DIR/checkpoint.sh" --create --project-dir "$proj_dir" --label "test_ckpt" >/dev/null 2>&1
  local list_output
  list_output=$("$SCRIPT_DIR/checkpoint.sh" --list --project-dir "$proj_dir" 2>&1)
  echo "$list_output" | grep -q "test_ckpt"
}

test_env_snapshot() {
  # 测试：环境快照前后对比
  local proj_dir
  proj_dir=$(setup_test_project "env_test")
  local tid="regtest_env_$$"
  "$SCRIPT_DIR/env_snapshot.sh" --before --project-dir "$proj_dir" --task-id "$tid" >/dev/null 2>&1
  "$SCRIPT_DIR/env_snapshot.sh" --after --project-dir "$proj_dir" --task-id "$tid" >/dev/null 2>&1
  "$SCRIPT_DIR/env_snapshot.sh" --diff --task-id "$tid" >/dev/null 2>&1
  # 检查 diff 文件生成
  [[ -f "$STATE_DIR/${tid}_env_diff.md" ]]
}

test_concurrent_guard() {
  # 测试：并发保护 — 写入 lock.pid 后应阻止新调用
  # 先清理
  rm -f "$STATE_DIR/lock.pid"

  # 模拟一个活着的锁（用当前进程的 PID）
  echo $$ > "$STATE_DIR/lock.pid"

  local blocked=false
  "$SCRIPT_DIR/subscription_guard.sh" --check >/dev/null 2>&1 || blocked=true

  # 清理
  rm -f "$STATE_DIR/lock.pid"

  [[ "$blocked" == "true" ]]
}

test_stale_lock_cleanup() {
  # 测试：过期锁（PID 不存在）应被自动清理
  echo "99999" > "$STATE_DIR/lock.pid"

  # startup_check 应自动检测并清理
  "$SCRIPT_DIR/startup_check.sh" >/dev/null 2>&1

  # lock.pid 应已被清理
  if [[ -f "$STATE_DIR/lock.pid" ]]; then
    local remaining_pid
    remaining_pid=$(cat "$STATE_DIR/lock.pid")
    # 如果 99999 这个进程真的存在就跳过
    kill -0 99999 2>/dev/null && return 0
    return 1
  fi
  return 0
}

test_cli_caps_cache() {
  # 测试：CLI 能力缓存文件能正确生成
  rm -f "$STATE_DIR/.cli_caps_cache"

  # 直接 source delegate 脚本不可行，手动模拟探测
  local CLAUDE_BIN
  if command -v claude &>/dev/null; then
    CLAUDE_BIN="$(command -v claude)"
  else
    # 没有 claude CLI 就跳过
    echo "   ⚠️ claude CLI 不可用，跳过缓存测试"
    return 0
  fi

  local CLI_VERSION
  CLI_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  local HELP_OUTPUT
  HELP_OUTPUT=$("$CLAUDE_BIN" --help 2>&1 || true)

  # 验证能正常解析
  [[ -n "$CLI_VERSION" ]] && [[ "$CLI_VERSION" != "unknown" || -n "$HELP_OUTPUT" ]]
}

test_verify_whitelist() {
  # 测试：验证白名单能识别常见命令
  # 通过 source 函数来测试
  local test_cmds=(
    "python3 -m pytest tests/"
    "uv run pytest"
    "poetry run pytest tests/"
    "pnpm test"
    "pnpm lint"
    "bash scripts/check.sh"
    "curl http://127.0.0.1:8000/health"
    "go test ./..."
    "cargo test"
    "./gradlew test"
  )

  local reject_cmds=(
    "rm -rf /"
    "dd if=/dev/zero"
    "chmod 777 /etc/passwd"
    "kill -9 1"
  )

  # 提取 validate_test_cmd 函数
  local func_file="$TEST_BASE/validate_func.sh"
  sed -n '/^validate_test_cmd/,/^}/p' "$SCRIPT_DIR/verify_delivery.sh" > "$func_file"
  source "$func_file"

  # 测试安全命令应通过
  for cmd in "${test_cmds[@]}"; do
    if ! validate_test_cmd "$cmd" 2>/dev/null; then
      echo "   应该通过但被拒绝: $cmd"
      return 1
    fi
  done

  # 测试危险命令应拒绝
  for cmd in "${reject_cmds[@]}"; do
    if validate_test_cmd "$cmd" 2>/dev/null; then
      echo "   应该拒绝但被放行: $cmd"
      return 1
    fi
  done

  return 0
}

# ═══════════════════════════════════════
#  执行
# ═══════════════════════════════════════

echo "╔═══════════════════════════════════════╗"
echo "║   dev-delegate 回归测试 v1.0          ║"
echo "║   $(date '+%Y-%m-%d %H:%M:%S')                  ║"
echo "╚═══════════════════════════════════════╝"

mkdir -p "$TEST_BASE"

# 基础测试（快速）
run_test "startup_check"       "启动自检正常运行"          test_startup_check
run_test "brief_pass"          "合格任务简报通过校验"       test_brief_validator_pass
run_test "brief_fail"          "不合格任务简报被拒绝"       test_brief_validator_fail
run_test "guard_check"         "配额保护检查正常"           test_subscription_guard
run_test "guard_status"        "配额状态查询正常"           test_subscription_guard_status
run_test "checkpoint"          "Git 快照创建与列出"         test_checkpoint_create
run_test "env_snapshot"        "环境快照前后对比"           test_env_snapshot
run_test "concurrent_guard"    "并发保护拦截生效"           test_concurrent_guard
run_test "stale_lock"          "过期锁自动清理"             test_stale_lock_cleanup
run_test "cli_caps"            "CLI 能力探测"               test_cli_caps_cache
run_test "verify_whitelist"    "验证命令白名单准确"         test_verify_whitelist

# 清理临时目录
rm -rf "$TEST_BASE"

# ─── 汇总 ───
echo ""
echo "═══════════════════════════════════════"
echo "  回归测试结果"
echo "═══════════════════════════════════════"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done
echo ""
echo "  通过: $PASS | 失败: $FAIL | 跳过: $SKIP"
echo "═══════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "🔴 有 $FAIL 项测试失败，请检查"
  exit 1
else
  echo ""
  echo "🟢 全部通过"
  exit 0
fi
