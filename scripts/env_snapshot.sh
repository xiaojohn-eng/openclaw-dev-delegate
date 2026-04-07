#!/usr/bin/env bash
# env_snapshot.sh — 环境快照对比
# 用途：在 Claude Code 执行前后各拍一次环境快照，检测环境漂移
#
# 用法：
#   ./env_snapshot.sh --before --project-dir DIR --task-id ID
#   ./env_snapshot.sh --after  --project-dir DIR --task-id ID
#   ./env_snapshot.sh --diff   --task-id ID

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$SKILL_DIR/state"

ACTION=""
PROJECT_DIR=""
TASK_ID=""

show_help() {
  cat <<'HELPEOF'
env_snapshot.sh — 环境快照对比

用法：
  ./env_snapshot.sh --before --project-dir DIR --task-id ID
  ./env_snapshot.sh --after  --project-dir DIR --task-id ID
  ./env_snapshot.sh --diff   --task-id ID

参数：
  --before           拍摄执行前快照
  --after            拍摄执行后快照
  --diff             对比前后快照
  --project-dir DIR  项目目录路径
  --task-id ID       任务唯一标识
  -h, --help         显示此帮助信息
HELPEOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     show_help ;;
    --before)      ACTION="before"; shift ;;
    --after)       ACTION="after"; shift ;;
    --diff)        ACTION="diff"; shift ;;
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --task-id)     TASK_ID="$2"; shift 2 ;;
    *) echo "❌ 未知参数: $1"; echo "使用 $0 --help 查看用法"; exit 1 ;;
  esac
done

if [[ -z "$TASK_ID" ]]; then
  echo "❌ 缺少 --task-id"
  exit 1
fi

mkdir -p "$STATE_DIR"

take_snapshot() {
  local PHASE=$1
  local PREFIX="$STATE_DIR/${TASK_ID}_env_${PHASE}"

  # M-01 修复：校验 before/after 时 PROJECT_DIR 非空
  if [[ -z "$PROJECT_DIR" ]]; then
    echo "⚠️  未指定 --project-dir，跳过项目目录大小统计"
  fi

  # Python 包列表
  pip3 list --format=freeze > "${PREFIX}_pip.txt" 2>/dev/null || echo "pip3 不可用" > "${PREFIX}_pip.txt"

  # 监听端口
  ss -tlnp 2>/dev/null | grep LISTEN > "${PREFIX}_ports.txt" || true

  # crontab
  crontab -l > "${PREFIX}_cron.txt" 2>/dev/null || echo "无 crontab" > "${PREFIX}_cron.txt"

  # 运行中的后台服务
  pgrep -af "uvicorn\|gunicorn\|node\|python3.*serve\|flask\|fastapi" > "${PREFIX}_services.txt" 2>/dev/null || echo "无相关服务" > "${PREFIX}_services.txt"

  # 磁盘空间
  df -h / > "${PREFIX}_disk.txt" 2>/dev/null || true

  # 项目目录大小
  if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
    du -sh "$PROJECT_DIR" > "${PREFIX}_project_size.txt" 2>/dev/null || true
  fi

  echo "📸 环境快照 [${PHASE}] 已保存"
}

show_diff() {
  local BEFORE_PREFIX="$STATE_DIR/${TASK_ID}_env_before"
  local AFTER_PREFIX="$STATE_DIR/${TASK_ID}_env_after"
  local DIFF_FILE="$STATE_DIR/${TASK_ID}_env_diff.md"
  local HAS_CHANGES=false

  {
  echo "## 环境变更报告：${TASK_ID}"
  echo ""

  # pip 包变更
  echo "### Python 包变更"
  if [[ -f "${BEFORE_PREFIX}_pip.txt" && -f "${AFTER_PREFIX}_pip.txt" ]]; then
    ADDED=$(comm -13 <(sort "${BEFORE_PREFIX}_pip.txt") <(sort "${AFTER_PREFIX}_pip.txt") || true)
    REMOVED=$(comm -23 <(sort "${BEFORE_PREFIX}_pip.txt") <(sort "${AFTER_PREFIX}_pip.txt") || true)

    if [[ -n "$ADDED" ]]; then
      HAS_CHANGES=true
      echo "新增的包："
      echo "$ADDED" | sed 's/^/  + /'
    fi
    if [[ -n "$REMOVED" ]]; then
      HAS_CHANGES=true
      echo "移除的包："
      echo "$REMOVED" | sed 's/^/  - /'
    fi
    if [[ -z "$ADDED" && -z "$REMOVED" ]]; then
      echo "  无变更"
    fi
  else
    echo "  ⚠️ 缺少前后快照，无法对比"
  fi
  echo ""

  # 端口变更
  echo "### 端口变更"
  if [[ -f "${BEFORE_PREFIX}_ports.txt" && -f "${AFTER_PREFIX}_ports.txt" ]]; then
    PORT_DIFF=$(diff "${BEFORE_PREFIX}_ports.txt" "${AFTER_PREFIX}_ports.txt" 2>/dev/null || true)
    if [[ -n "$PORT_DIFF" ]]; then
      HAS_CHANGES=true
      echo "$PORT_DIFF" | sed 's/^/  /'
    else
      echo "  无变更"
    fi
  fi
  echo ""

  # crontab 变更
  echo "### Crontab 变更"
  if [[ -f "${BEFORE_PREFIX}_cron.txt" && -f "${AFTER_PREFIX}_cron.txt" ]]; then
    CRON_DIFF=$(diff "${BEFORE_PREFIX}_cron.txt" "${AFTER_PREFIX}_cron.txt" 2>/dev/null || true)
    if [[ -n "$CRON_DIFF" ]]; then
      HAS_CHANGES=true
      echo "$CRON_DIFF" | sed 's/^/  /'
    else
      echo "  无变更"
    fi
  fi
  echo ""

  # 服务变更
  echo "### 后台服务变更"
  if [[ -f "${BEFORE_PREFIX}_services.txt" && -f "${AFTER_PREFIX}_services.txt" ]]; then
    SVC_DIFF=$(diff "${BEFORE_PREFIX}_services.txt" "${AFTER_PREFIX}_services.txt" 2>/dev/null || true)
    if [[ -n "$SVC_DIFF" ]]; then
      HAS_CHANGES=true
      echo "$SVC_DIFF" | sed 's/^/  /'
    else
      echo "  无变更"
    fi
  fi
  echo ""

  # 汇总
  if [[ "$HAS_CHANGES" == "true" ]]; then
    echo "### ⚠️ 检测到环境变更"
    echo "Claude Code 执行期间修改了系统环境，请确认这些变更是预期的。"
  else
    echo "### ✅ 环境无变更"
  fi

  } > "$DIFF_FILE" 2>&1

  cat "$DIFF_FILE"
  echo ""
  echo "📄 环境对比报告: $DIFF_FILE"
}

case "$ACTION" in
  before) take_snapshot "before" ;;
  after)  take_snapshot "after" ;;
  diff)   show_diff ;;
  *)
    echo "用法: $0 [--before|--after|--diff] --task-id ID [--project-dir DIR]"
    exit 1
    ;;
esac
