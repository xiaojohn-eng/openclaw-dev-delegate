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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create)      ACTION="create"; shift ;;
    --rollback)    ACTION="rollback"; shift ;;
    --list)        ACTION="list"; shift ;;
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    *) shift ;;
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
    # 找到最近的 checkpoint 提交
    CHECKPOINT_HASH=$(git log --oneline --all | grep "checkpoint:" | head -1 | awk '{print $1}')

    if [[ -z "$CHECKPOINT_HASH" ]]; then
      echo "❌ 未找到 checkpoint 提交，无法回滚"
      exit 1
    fi

    CHECKPOINT_MSG=$(git log --oneline -1 "$CHECKPOINT_HASH")
    echo "⚠️  准备回滚到: $CHECKPOINT_MSG"
    echo "   当前 HEAD: $(git log --oneline -1 HEAD)"
    echo ""

    # 显示将要丢弃的变更
    CHANGES=$(git diff --stat "$CHECKPOINT_HASH" HEAD 2>/dev/null || echo "无法计算差异")
    echo "将要丢弃的变更："
    echo "$CHANGES"
    echo ""

    # 执行回滚
    git reset --hard "$CHECKPOINT_HASH"
    echo "✅ 已回滚到: $CHECKPOINT_MSG"
    ;;

  list)
    echo "📋 Checkpoint 列表："
    git log --oneline --all | grep "checkpoint:" | head -20 | while IFS= read -r line; do
      HASH=$(echo "$line" | awk '{print $1}')
      MSG=$(echo "$line" | cut -d' ' -f2-)
      DATE=$(git log -1 --format="%ci" "$HASH" 2>/dev/null | cut -d' ' -f1,2)
      echo "  $HASH | $DATE | $MSG"
    done

    TOTAL=$(git log --oneline --all | grep -c "checkpoint:" || echo 0)
    echo ""
    echo "共 $TOTAL 个快照"
    ;;

  *)
    echo "用法: $0 [--create|--rollback|--list] --project-dir DIR [--label LABEL]"
    exit 1
    ;;
esac
