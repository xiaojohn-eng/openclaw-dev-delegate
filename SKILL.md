---
name: dev-delegate
description: 开发委托技能 — OpenClaw 调用 Claude Code 开发时的职责分离、防幻觉、防打断、证据链验证
version: 2.2.0
triggers:
  - 调用 claude code
  - 用 claude code 做
  - 让 claude code 开发
  - 交给 claude code
  - 委托开发
  - claude code 开发
  - claude code 写代码
  - claude code 实现
  - claude code 搭建
---

# dev-delegate — 开发委托技能

> **版本**：2.2.0
> **作者**：军哥 + Claude Code
> **创建日期**：2026-04-06
> **更新日期**：2026-04-07
> **用途**：当用户要求 OpenClaw 调用 Claude Code 进行软件开发时，强制执行职责分离、防幻觉、防打断、证据链验证。

---

## 触发条件

当用户消息包含以下任意关键词时，自动激活此技能：

- "调用 claude code" + "开发/写代码/实现/搭建"
- "用 claude code 做"
- "让 claude code 开发"
- "交给 claude code"
- "委托开发"

激活后，整个开发任务生命周期内持续生效，直到用户明确说"完成/结束/关闭任务"。

---

## 铁律（不可违反，任何情况下不可绕过）

### 铁律 1：禁写规则
OpenClaw 在此技能激活期间，**绝对禁止**用任何方式直接写入代码文件。

禁止的操作模式：
```
❌ cat > xxx.py <<'EOF'
❌ echo "xxx" > xxx.py
❌ python3 - <<'PY' ... 写文件
❌ printf/tee/sed 写入代码文件
❌ 任何向 .py/.js/.ts/.go/.rs/.java/.kt/.cpp/.c/.h/.vue/.jsx/.tsx/.css/.html 文件的写入
```

唯一允许的代码产出方式：
```
✅ 通过 delegate_to_claude.sh 调用 Claude Code CLI
```

例外：OpenClaw 可以写入以下非代码文件：
- `.dev-delegate/` 下的状态文件（.md/.json/.jsonl）
- 任务简报模板
- 进度报告

### 铁律 2：证据规则
每次声称"阶段完成/任务完成"时，**必须**执行 `verify_delivery.sh` 并附带完整输出。
- 输出包含任何 ❌ → 不得声称完成
- 无验证输出 = 未完成
- 禁止编造验证结果

### 铁律 3：锁定规则
技能激活后启动任务锁：
- heartbeat 检查 → 只回 `HEARTBEAT_OK`，不展开
- 周报催收/统计 → 排队，任务完成后处理
- 非紧急消息 → 缓存
- 只有用户明确说"停下/暂停/切任务"才能打断

### 铁律 4：诚实规则
- Claude Code 调用失败/超时/无产出时 → 如实汇报"调用未成功"+ 具体错误
- 禁止在 Claude Code 未完成时声称任务已完成
- 禁止把 OpenClaw 自己的操作说成 Claude Code 的产出
- 进度不明时说"等待 Claude Code 返回"，不编造进度

### 铁律 5：分工规则

| 角色 | 允许做的 | 禁止做的 |
|------|---------|---------|
| OpenClaw | 需求沟通、任务拆解、生成任务简报、调用 Claude Code、读文件验证、跑测试、汇报 | 写代码、改代码、声称自己是开发者 |
| Claude Code | 写代码、改代码、跑测试、修 bug、架构设计 | （由 Claude Code 自行管理） |

---

## OpenClaw 能力边界声明

### ✅ 我能做的
- 理解用户需求并拆解为子任务
- 生成符合模板的任务简报
- 通过 delegate_to_claude.sh 调用 Claude Code CLI
- 读取文件验证产出是否存在
- 执行 pytest / npm test 等验证命令
- 执行 verify_delivery.sh 生成证据链
- 监控 Claude Code 会话进度
- 生成结构化进度报告
- 跟用户沟通进展和决策点

### ❌ 我不能做的（硬边界）
- 写任何代码文件
- 修改任何代码文件
- 声称我自己写的代码是 Claude Code 的产出
- 在 Claude Code 未完成时声称任务已完成
- 用 bash heredoc/echo/cat/tee/sed 写入代码

### ⚠️ 遇到以下情况必须如实上报用户
- Claude Code 调用超时（>10 分钟无输出）
- Claude Code 返回错误
- 验证脚本跑出 ❌
- 任务简报信息不足，需要用户补充
- 达到调用频率限制
- 用户正在使用 Claude Code（需等待）

---

## 工作流程

### Phase 0：需求确认（OpenClaw 执行）
1. 与用户沟通，理解需求
2. 拆解为可执行的子任务清单（大项目拆 ≤5 个子任务）
3. 为每个子任务生成任务简报（使用 templates/task_brief.md）
4. 执行 task_brief_validator.sh 校验简报质量
5. 用户确认后，锁定任务，进入 Phase 1

### Phase 1：委托开发（调用 Claude Code）
1. 执行 subscription_guard.sh 检查调用条件
   - 是否有其他会话在跑
   - 用户是否在用 Claude Code
   - 是否达到频率限制
2. 执行 pre-task git checkpoint
   ```bash
   cd {project_dir} && git add -A && git commit -m "checkpoint: before {task_id}" --allow-empty
   ```
3. 调用 delegate_to_claude.sh 发起 Claude Code 会话
4. 同时启动 monitor_claude.sh 监控进度
5. 等待 Claude Code 完成

### Phase 2：验收检查（OpenClaw 执行）
1. 执行 verify_delivery.sh 验证产出
2. 读取 Claude Code 实际修改的文件列表
3. 执行项目测试（pytest / npm test 等）
4. 生成证据链汇报（使用 templates/phase_report.md）

### Phase 3：结果处理
- 验收通过 → 生成汇报发给用户（带证据）
- 验收失败 → 生成失败报告，回到 Phase 1（带具体问题重新调 Claude Code）
- 连续失败 2 次 → 上报用户决策（附带所有失败信息）

### Phase 4：交接与续接（多子任务时）
1. 当前子任务完成后，生成 handoff.md 写入 .dev-delegate/
2. 更新 project_state.md
3. 将 handoff.md 作为下一个子任务的上下文输入
4. 进入下一个子任务的 Phase 1

---

## 执行模式（前台 vs 后台）

### 前台模式（默认）
Claude Code 阻塞执行，OpenClaw 等待完成后再做验证和汇报。
- 适合：小任务（<10 分钟）
- OpenClaw 在等待期间**不能做其他事**
- 但 monitor_claude.sh 在后台提供真实进度

### 后台模式（--background）
Claude Code 后台执行，OpenClaw 立即返回，可以继续跟用户聊天。
- 适合：大任务（>10 分钟）
- 用户问进度时，OpenClaw 读 monitor.log 给真实信息
- Claude Code 跑完后会写 `{task_id}_done.json` 完成标记

```bash
# 后台启动
delegate_to_claude.sh --project-dir DIR --task-id ID --task-brief FILE --background

# 查询状态（OpenClaw 随时可调）
delegate_to_claude.sh --status --task-id ID

# 实时监控
tail -f ~/.openclaw/skills/dev-delegate/state/{task_id}_monitor.log
```

### OpenClaw 在后台模式下的行为规则
1. 发起后台任务后，立即告诉用户"已在后台启动"
2. 用户问进度 → 调 `--status` 查真实状态，不编造
3. 用户要求做别的事 → 正常处理，不受影响
4. 检测到 `{task_id}_done.json` 存在 → 主动汇报完成
5. 如果用户没问，每 10 分钟主动检查一次完成状态

### 进度反馈规则（防止编造进度）
- **有 monitor.log 数据** → 读最近 3 条日志，如实转述
  - 例如："Claude Code 正在修改 core/modules/risk_guard/service.py，项目文件数已从 58 增加到 63"
- **无 monitor.log 数据** → 只说"Claude Code 仍在运行中，暂无新文件变更"
- **绝对禁止**：编造具体的阶段完成情况、编造百分比进度、编造文件名

---

## 权限处理（解决确认框问题）

### 问题
Claude Code 在交互模式下会弹出权限确认框。OpenClaw 通过 `claude -p` 调用时无法交互式确认。

### 解决方案
调用时使用 `--permission-mode auto`，让 Claude Code 自动批准操作：

```bash
claude -p \
  --permission-mode auto \                    # 自动批准（用户已全局授权）
  --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \  # 明确允许的工具
  --cwd /root/project \                       # 工作目录
  "任务内容"
```

### 禁止的做法
```
❌ --dangerously-skip-permissions     # 跳过所有安全检查，不安全
❌ --permission-mode bypassPermissions # 等效于上面，不安全
❌ 用 heredoc 大段写文件绕过 Claude Code  # 会被 obfuscation-detected 拦截
```

### 为什么用 auto 而不是 bypass
- `auto`：遵守用户已配置的权限规则，自动批准已授权的操作
- `bypass`：跳过所有安全检查，包括防注入保护
- 用户已经是 $200 Max 订阅并配置了全自动权限，`auto` 就够了

---

## 订阅配额保护（Max $200 计划）

### 调用规则
- 同时只允许 1 个 Claude Code 会话
- 调用间隔最少 30 秒
- 单小时最多 10 次调用
- 单日最多 50 次调用

### 用户优先级
- 调用前检查用户是否正在使用 Claude Code
- 用户在用 → OpenClaw 暂停等待，不抢占
- 用户退出 → 自动恢复任务

### Rate Limit 处理
- 遇到 429/rate limit → 等 5 分钟后重试
- 最多重试 2 次
- 重试仍失败 → 上报用户

### 调用日志
每次调用记录到 `.dev-delegate/call_log.jsonl`：
```json
{
  "call_time": "ISO时间",
  "task_id": "任务ID",
  "duration_seconds": 123,
  "success": true,
  "files_changed": 5,
  "session_id": "claude会话ID"
}
```

---

## 任务简报质量门槛

任务简报必须包含以下 6 个字段，每个字段必须有实质内容（≥20字），否则不允许发起 Claude Code 调用：

1. **背景**：为什么做这个任务
2. **目标**：做到什么程度算完成（可量化的验收标准）
3. **约束**：技术限制、业务边界、不能做什么
4. **输入**：Claude Code 需要读取的文件路径列表
5. **输出**：期望产出的文件列表 + 每个文件的作用
6. **依赖**：环境要求、前置条件、已有代码状态

---

## 失败恢复机制

### Git Checkpoint
- 每次调 Claude Code 前：自动 `git commit` 做快照
- Claude Code 完成后验证失败 → 可回滚到快照
- 回滚命令：`checkpoint.sh --rollback --project-dir DIR --force`
- 不带 `--force` 只显示回滚预览，不执行

### 崩溃断点续接（crash_recover.sh）
当 Claude Code 中途崩溃（超时/被 kill/网络断）时：

1. **不要立即回滚** — 可能已完成 80% 的工作
2. 执行 `crash_recover.sh` 分析半成品状态（退出码: 0=KEEP, 1=ROLLBACK, 2=RETRY, 3=KEEP_AND_FIX）
3. 脚本会自动：
   - 对比 checkpoint 和当前状态，计算已完成的文件数
   - 跑测试看半成品是否可用
   - 根据结果给出建议（保留/回滚/保留并修复）
   - 如果建议保留，自动生成**续接任务简报**

4. 决策矩阵：

| 测试通过 | 文件变更数 | 决策 |
|---------|----------|------|
| ✅ 通过 | >3 个 | **保留**，续接完成剩余部分 |
| ❌ 失败 | >3 个 | **保留但修复**，续接任务聚焦修复 |
| ❌ 失败 | ≤3 个 | **回滚**，用原始简报重试 |
| 任意 | 0 个 | **直接重试**，启动阶段就失败了 |

### 重试策略
- 第 1 次失败：分析错误，调整任务简报，重新调用
- 第 2 次失败：上报用户，附带两次的错误信息和 diff
- 禁止超过 2 次盲目重试

### 失败精准反馈
验证不通过时，verify_delivery.sh 会自动生成「失败反馈模板」，
OpenClaw 在重新调用 Claude Code 时必须将此模板作为上下文传入，
包含具体失败项和修复要求，避免 Claude Code 重复犯同样的错误。

---

## 环境漂移检测（env_snapshot.sh）

Claude Code 执行 Bash 工具时可能改变系统环境（pip install、占端口、改 crontab）。

### 机制
- **调用前**：自动拍摄环境快照（pip 包、端口、crontab、后台服务）
- **调用后**：再拍一次
- **验证时**：对比前后差异，标注 Claude Code 引入的环境变更

### verify_delivery.sh 中的体现
验证报告会多一栏「环境变更检查」，列出 Claude Code 新增/移除的 pip 包、
新占用的端口等。用户一眼就能看到 Claude Code 偷偷装了什么。

---

## OpenClaw 重启恢复（startup_check.sh）

OpenClaw 重启后可能丢失任务上下文。此脚本应在 OpenClaw 启动时自动执行。

### 检查内容
- 是否有后台 Claude Code 任务仍在运行
- 是否有已完成但未汇报用户的任务
- 是否有异常中断的任务需要恢复
- 是否有过期的锁文件需要清理

### 使用方式
```bash
# OpenClaw 启动时自动执行
startup_check.sh

# 清理过期状态
startup_check.sh --cleanup
```

---

## 项目状态持久化

每次任务完成后，自动在项目根目录写入 `.dev-delegate-status.md`，
记录最后一次任务的状态、文件变动数、Claude Code 会话 ID。

OpenClaw 下次进入同一项目时，应先读取此文件了解上下文，
而不是从零开始重新分析项目。

---

## 多项目并行

- 最多同时 1 个开发任务（subscription_guard.sh 强制执行）
- 每个任务用独立 git 分支隔离
- 用户切话题时：保存当前任务状态，不终止后台 Claude Code 会话
- 切回时：从 .dev-delegate-status.md 恢复上下文

---

## 结构化输出与 JSON 模式

多个脚本支持 `--json` 标志输出机器可读 JSON，便于程序化集成：

```bash
# 任务状态查询（结构化）
delegate_to_claude.sh --status --task-id ID --json
# → {"task_id":"...", "status":"COMPLETED|RUNNING|FAILED|TIMEOUT|INTERRUPTED|UNKNOWN", ...}

# 版本与依赖自检
selfcheck.sh --json
# → {"ok":true, "checks":[...], "summary":{"pass":N,"fail":N,"warn":N}}

# 启动自检
startup_check.sh --json
# → {"summary":{"running":0,"completed_unreported":0,...}, "tasks":[...]}

# 状态目录清理
state_cleanup.sh --json
# → {"cleaned_files":N, "cleaned_bytes":N, ...}
```

### 状态枚举

`--status --json` 返回的 `status` 字段使用以下枚举值：

| 状态 | 含义 | 来源 |
|------|------|------|
| `RUNNING` | 任务进程仍在执行 | PID 存活检测 |
| `COMPLETED` | 正常完成（exit_code=0） | done.json 或 call_log |
| `FAILED` | 异常退出 | done.json 或 call_log |
| `TIMEOUT` | 执行超时（exit_code=124） | done.json 或 call_log |
| `INTERRUPTED` | 进程被终止 | PID 已死但有记录 |
| `UNKNOWN` | 无任何状态信息 | 无 done.json、无 PID、无日志 |

v2.2.0 新增：当 `done.json` 和 PID 均不存在时，自动从 `call_log.jsonl` 恢复历史状态，大幅减少 `UNKNOWN`。

---

## 验证报告结构化字段

`verify_delivery.sh` 生成的报告包含以下标准化字段，便于归档和自动化处理：

| 字段 | 说明 |
|------|------|
| `task_id` | 任务唯一标识 |
| `task_token` | 本次调用的唯一令牌（task_id + 时间戳 + 随机数） |
| `final_verdict` | `PASS` 或 `FAIL` |
| `pass_count` | 通过的检查项数 |
| `fail_count` | 失败的检查项数 |
| `warn_count` | 警告的检查项数 |
| `verified_at` | 验证执行时间（ISO 8601） |
| `user_artifacts` | 用户交付文件列表 |
| `internal_artifacts` | 技能内部状态文件列表 |

---

## 状态目录管理（state_cleanup.sh）

`state/` 目录存放运行时产物，长期使用后可能膨胀。`state_cleanup.sh` 提供安全的清理/归档能力：

```bash
# 预览可清理的文件（dry-run，默认）
state_cleanup.sh

# 实际执行清理（删除 30 天前的过期文件）
state_cleanup.sh --execute

# 归档后清理（先打包到 state/archive/ 再删除）
state_cleanup.sh --archive

# 自定义保留天数
state_cleanup.sh --execute --max-age 7

# JSON 格式报告
state_cleanup.sh --json
```

保护规则：
- 永不删除 `active_task.json`、`call_log.jsonl`、`.cli_caps_cache`
- 不删除运行中任务的关联文件
- `call_log.jsonl` 仅截断（保留最近 500 条），不删除

---

## 文件结构

```
~/.openclaw/skills/dev-delegate/
├── SKILL.md                       # 本文件
├── README.md                      # 快速上手指南
├── CHANGELOG.md                   # 版本变更记录
├── .gitignore                     # 排除 state/ 和临时产物
├── scripts/
│   ├── delegate_to_claude.sh      # 标准化 Claude Code 调用（前台/后台/--json）
│   ├── verify_delivery.sh         # 产出验证（含结构化归档字段+失败反馈）
│   ├── task_brief_validator.sh    # 任务简报质量校验
│   ├── subscription_guard.sh      # 订阅配额保护
│   ├── monitor_claude.sh          # 实时进度监控
│   ├── checkpoint.sh              # Git 快照管理
│   ├── progress_report.sh         # 证据链汇报生成
│   ├── env_snapshot.sh            # 环境快照对比
│   ├── crash_recover.sh           # 崩溃断点续接
│   ├── startup_check.sh           # OpenClaw 启动自检（--json）
│   ├── selfcheck.sh               # 版本/依赖自检（--json）
│   ├── state_cleanup.sh           # 状态目录清理与归档
│   ├── mock_claude.sh             # 测试用 mock CLI
│   └── regression_test.sh         # 回归测试（20 个场景）
├── templates/
│   ├── task_brief.md              # 任务简报模板（含自动验收命令）
│   ├── phase_report.md            # 阶段汇报模板
│   └── handoff.md                 # 子任务交接模板
├── .github/
│   └── workflows/
│       └── ci.yml                 # GitHub Actions 回归测试
└── state/                         # 运行时状态（自动管理，.gitignore 排除）
    ├── active_task.json           # 当前活跃任务
    ├── call_log.jsonl             # 调用日志
    └── lock.pid                   # 任务锁文件
```
