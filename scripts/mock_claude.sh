#!/usr/bin/env bash
# mock_claude.sh — 模拟 Claude CLI 行为，用于回归测试
#
# 行为模式（通过环境变量控制）：
#   MOCK_MODE=success     正常完成，修改文件，输出修改清单（默认）
#   MOCK_MODE=fail        执行失败，退出码 1
#   MOCK_MODE=timeout     模拟长时间运行（被 timeout 杀掉）
#   MOCK_MODE=crash       模拟崩溃（SIGKILL 自身）
#
# 接收参数：模拟 claude -p "..." 格式
# 识别工作目录：从参数中的 --add-dir 或当前 cwd 获取

set -uo pipefail

MOCK_MODE="${MOCK_MODE:-success}"
MOCK_DELAY="${MOCK_DELAY:-1}"  # 模拟执行时间（秒）

# 解析参数，提取 prompt 和 project dir
PROMPT=""
PROJECT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)              PROMPT="$2"; shift 2 ;;
    --add-dir)       PROJECT_DIR="$2"; shift 2 ;;
    --cwd)           PROJECT_DIR="$2"; shift 2 ;;
    --output-format) shift 2 ;;
    --permission-mode) shift 2 ;;
    --dangerously-skip-permissions) shift ;;
    --allowedTools)  shift 2 ;;
    --allowed-tools) shift 2 ;;
    --version)       echo "mock-claude 1.0.0 (regression test)"; exit 0 ;;
    --help)
      cat <<'HELPEOF'
Usage: mock_claude [options]

Options:
  -p <prompt>                 Non-interactive prompt
  --output-format <format>    Output format (text, json)
  --permission-mode <mode>    Permission mode (auto, default)
  --allowedTools <tools>      Allowed tools
  --add-dir <dir>             Additional directory
  --cwd <dir>                 Working directory
  --version                   Show version
  --help                      Show help
HELPEOF
      exit 0
      ;;
    *) shift ;;
  esac
done

# 如果没有通过参数获取 project dir，用 cwd
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$(pwd)"

sleep "$MOCK_DELAY"

case "$MOCK_MODE" in
  success)
    # 模拟 Claude Code 修改文件
    if [[ -d "$PROJECT_DIR" ]]; then
      # 创建一个新文件
      mkdir -p "$PROJECT_DIR/src"
      cat > "$PROJECT_DIR/src/greet.py" <<'PYEOF'
def greet(name: str) -> str:
    """Return a greeting message."""
    return f"Hello, {name}!"

if __name__ == "__main__":
    print(greet("World"))
PYEOF

      # 修改已有文件（如果存在）
      if [[ -f "$PROJECT_DIR/src/main.py" ]]; then
        echo "" >> "$PROJECT_DIR/src/main.py"
        echo "from src.greet import greet  # added by Claude Code" >> "$PROJECT_DIR/src/main.py"
      fi

      # 添加到 git
      if cd "$PROJECT_DIR" && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        git add -A 2>/dev/null || true
      fi
    fi

    # 输出修改清单（模拟 Claude Code 输出格式）
    cat <<OUTEOF
=== 修改文件清单 ===
[新增] src/greet.py — greet 函数实现
[修改] src/main.py — 导入 greet 模块

=== 测试结果 ===
手动验证：python3 -c "from src.greet import greet; print(greet('test'))" → Hello, test!

=== 遗留问题 ===
无
OUTEOF
    exit 0
    ;;

  fail)
    echo "Error: Claude Code encountered an unexpected error during execution" >&2
    exit 1
    ;;

  timeout)
    # 持续运行直到被 timeout 命令杀掉
    while true; do
      sleep 1
    done
    ;;

  crash)
    # 模拟崩溃：先做一点工作再 SIGKILL 自身
    if [[ -d "$PROJECT_DIR" ]]; then
      mkdir -p "$PROJECT_DIR/src"
      echo "# partial work" > "$PROJECT_DIR/src/partial.py"
      if cd "$PROJECT_DIR" && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        git add -A 2>/dev/null || true
      fi
    fi
    kill -9 $$
    ;;

  *)
    echo "Unknown MOCK_MODE: $MOCK_MODE" >&2
    exit 1
    ;;
esac
