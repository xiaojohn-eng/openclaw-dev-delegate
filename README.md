# dev-delegate — OpenClaw 开发委托技能

> OpenClaw 调用 Claude Code 进行软件开发时的职责分离框架：防幻觉、防打断、证据链验证。

## 解决什么问题

当 OpenClaw 被要求"调用 Claude Code 开发"时，经常出现以下问题：

| 问题 | 表现 |
|------|------|
| **幻觉** | OpenClaw 自己用 bash heredoc 写代码，冒充 Claude Code 产出 |
| **虚假汇报** | 声称"阶段完成"但实际没有可验证的产出 |
| **被打断** | 心跳检查、周报催收等低优先级任务打断开发主线 |
| **权限卡死** | 用 `--dangerously-skip-permissions` 绕过安全检查 |
| **进度编造** | 不知道 Claude Code 跑到哪了，编造百分比进度 |

## 核心机制

### 职责分离
- **OpenClaw**：需求沟通、任务拆解、验收、汇报
- **Claude Code**：写代码、改代码、跑测试、修 bug
- OpenClaw **禁止**直接写入任何代码文件

### 证据链验证
每次声称"完成"必须执行 `verify_delivery.sh`，输出包含：
- Claude Code 会话是否真实存在
- Git 变更是否真实发生
- 测试是否通过
- 自动验收命令是否全部成功
- 环境是否被意外修改

### 订阅配额保护（Max $200 计划）
- 用户优先级：用户在用 Claude Code 时 OpenClaw 自动让路
- 频率限制：单小时 ≤10 次，单日 ≤50 次
- 并发控制：同时只允许 1 个 Claude Code 会话

### 崩溃恢复
- 每次调用前自动 git checkpoint
- 中途崩溃时智能决策：保留半成品 / 回滚 / 断点续接
- 自动生成续接任务简报

## 文件结构

```
dev-delegate/
├── SKILL.md                       # 技能主文件（规则+流程）
├── scripts/
│   ├── delegate_to_claude.sh      # 标准化 Claude Code 调用（前台/后台）
│   ├── verify_delivery.sh         # 产出验证（7项检查+失败反馈）
│   ├── task_brief_validator.sh    # 任务简报质量校验
│   ├── subscription_guard.sh      # 订阅配额保护
│   ├── monitor_claude.sh          # 实时进度监控
│   ├── checkpoint.sh              # Git 快照/回滚
│   ├── progress_report.sh         # 证据链汇报生成
│   ├── env_snapshot.sh            # 环境快照对比
│   ├── crash_recover.sh           # 崩溃断点续接
│   └── startup_check.sh           # OpenClaw 启动自检
├── templates/
│   ├── task_brief.md              # 任务简报模板
│   ├── phase_report.md            # 阶段汇报模板
│   └── handoff.md                 # 子任务交接模板
└── state/                         # 运行时状态（自动管理）
```

## 安装

将整个目录复制到 OpenClaw 的 workspace 技能目录：

```bash
cp -r dev-delegate ~/.openclaw/workspace/skills/dev-delegate
```

验证安装：

```bash
openclaw skills info dev-delegate
# 应显示: 📦 dev-delegate ✓ Ready
```

## 使用

技能通过触发词自动激活。当你对 OpenClaw 说：

- "调用 claude code 开发 xxx"
- "让 claude code 写 xxx"
- "委托开发 xxx"

OpenClaw 会自动进入 dev-delegate 工作流。

### 手动使用脚本

```bash
SKILL_DIR=~/.openclaw/workspace/skills/dev-delegate/scripts

# 1. 检查调用条件
$SKILL_DIR/subscription_guard.sh --check

# 2. 校验任务简报
$SKILL_DIR/task_brief_validator.sh /path/to/brief.md

# 3. 调用 Claude Code（前台）
$SKILL_DIR/delegate_to_claude.sh \
  --project-dir /root/my-project \
  --task-id task_001 \
  --task-brief /path/to/brief.md

# 3b. 调用 Claude Code（后台）
$SKILL_DIR/delegate_to_claude.sh \
  --project-dir /root/my-project \
  --task-id task_001 \
  --task-brief /path/to/brief.md \
  --background

# 4. 查看后台任务状态
$SKILL_DIR/delegate_to_claude.sh --status --task-id task_001

# 5. 验证产出
$SKILL_DIR/verify_delivery.sh \
  --project-dir /root/my-project \
  --task-id task_001

# 6. 生成汇报
$SKILL_DIR/progress_report.sh \
  --project-dir /root/my-project \
  --task-id task_001 \
  --phase "Phase 1: 核心开发"
```

## 依赖

- OpenClaw 2026.4.x+
- Claude Code CLI (`claude` 命令)
- Python 3.10+
- Git
- Bash 4+

## 许可

MIT
