#!/usr/bin/env bash
# checkpoint.sh — Git 快照管理
# 用途：在调用 Claude Code 前后创建 git 快照，支持回滚
#
# 用法：
#   ./checkpoint.sh --create --project-dir DIR --label LABEL
#   ./checkpoint.sh --rollback --project-dir DIR
#   ./checkpoint.sh --list --project-dir DIR

set -uo pipefail

ACTION=""
PROJECT_DIR=""
LABEL=""
FORCE=false

show_help() {
  cat <<'HELPEOF'
checkpoint.sh — Git 快照管理

用法：
  ./checkpoint.sh --create --project-dir DIR --label LABEL
  ./checkpoint.sh --rollback --project-dir DIR [--force]
  ./checkpoint.sh --list --project-dir DIR

参数：
  --create           创建快照
  --rollback         回滚到最近的快照
  --list             列出所有快照
  --project-dir DIR  项目目录路径
  --label LABEL      快照标签
  --force            确认执行回滚（不可逆操作）
  -h, --help         显示此帮助信息
HELPEOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     show_help ;;
    --create)      ACTION="create"; shift ;;
    --rollback)    ACTION="rollback"; shift ;;
    --list)        ACTION="list"; shift ;;
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --force)       FORCE=true; shift ;;
    *) echo "❌ 未知参数: $1"; echo "使用 $0 --help 查看用法"; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  echo "❌ 缺少 --project-dir"
  exit 1
fi

cd "$PROJECT_DIR" || { echo "❌ 无法进入 $PROJECT_DIR"; exit 1; }

# 确保是 git 仓库
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  echo "⚠️  $PROJECT_DIR 不是 git 仓库，正在初始化..."
  git init
  git add -A
  git commit -m "initial: project snapshot" --allow-empty
  echo "✅ Git 仓库已初始化"
fi

case "$ACTION" in
  create)
    LABEL="${LABEL:-checkpoint_$(date +%Y%m%d_%H%M%S)}"

    # 暂存所有变更
    git add -A

    # 检查是否有东西需要提交
    if git diff --cached --quiet 2>/dev/null; then
      echo "📸 无需快照（无未提交变更）"
      echo "   当前 HEAD: $(git rev-parse --short HEAD)"
    else
      git commit -m "checkpoint: $LABEL" --allow-empty-message
      echo "📸 快照已创建"
      echo "   标签: $LABEL"
      echo "   提交: $(git rev-parse --short HEAD)"
      echo "   变更: $(git diff --stat HEAD~1 2>/dev/null | tail -1)"
    fi
    ;;

  rollback)
    # H-03 修复：只搜索当前分支（去掉 --all 避免跨分支选错）
    CHECKPOINT_HASH=$(git log --oneline | grep "checkpoint:" | head -1 | awk '{print $1}')

    if [[ -z "$CHECKPOINT_HASH" ]]; then
      echo "❌ ���找到 checkpoint 提交，无法回滚"
      exit 1
    fi

    CHECKPOINT_MSG=$(git log --oneline -1 "$CHECKPOINT_HASH")
    echo "⚠️  准备���滚到: $CHECKPOINT_MSG"
    echo "   当前 HEAD: $(git log --oneline -1 HEAD)"
    echo ""

    # 显示将要丢弃的变更
    CHANGES=$(git diff --stat "$CHECKPOINT_HASH" HEAD 2>/dev/null || echo "无法计算差异")
    echo "��要丢弃的变更："
    echo "$CHANGES"
    echo ""

    # L-01 修复：需要 --force 标志才执行回滚，否则只显示信息
    if [[ "${FORCE:-}" == "true" ]]; then
      git reset --hard "$CHECKPOINT_HASH"
      echo "✅ 已回��到: $CHECKPOINT_MSG"
    else
      echo "⚠️  这是不可逆操作。添加 --force 参数确认执行回滚："
      echo "   $0 --rollback --project-dir $PROJECT_DIR --force"
    fi
    ;;

  list)
    echo "📋 Checkpoint 列表（当前分支）："
    git log --oneline | grep "checkpoint:" | head -20 | while IFS= read -r line; do
      HASH=$(echo "$line" | awk '{print $1}')
      MSG=$(echo "$line" | cut -d' ' -f2-)
      DATE=$(git log -1 --format="%ci" "$HASH" 2>/dev/null | cut -d' ' -f1,2)
      echo "  $HASH | $DATE | $MSG"
    done

    TOTAL=$(git log --oneline | grep -c "checkpoint:" || echo 0)
    echo ""
    echo "共 $TOTAL 个快照"
    ;;

  *)
    echo "用法: $0 [--create|--rollback|--list] --project-dir DIR [--label LABEL]"
    exit 1
    ;;
esac
