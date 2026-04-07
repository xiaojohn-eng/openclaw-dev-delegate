# dev-delegate

> OpenClaw 调用 Claude Code 开发时的职责分离、防幻觉、防打断、证据链验证技能。

## 快速开始

```bash
# 1. 自检环境
./scripts/selfcheck.sh

# 2. 前台委托开发
./scripts/delegate_to_claude.sh \
  --project-dir /path/to/project \
  --task-id my_task_01 \
  --task-brief /path/to/brief.md

# 3. 验证产出
./scripts/verify_delivery.sh \
  --project-dir /path/to/project \
  --task-id my_task_01

# 4. 查询任务状态（JSON）
./scripts/delegate_to_claude.sh --status --task-id my_task_01 --json
```

## 核心能力

| 脚本 | 作用 |
|------|------|
| `delegate_to_claude.sh` | 标准化 Claude Code 调用（前台/后台），支持 `--json` 状态查询 |
| `verify_delivery.sh` | 产出验证 + 结构化归档（task_token / final_verdict / artifacts） |
| `selfcheck.sh` | 环境依赖自检（`--json` 支持） |
| `startup_check.sh` | 启动时恢复断点、清理过期锁（`--json` 支持） |
| `state_cleanup.sh` | 状态目录清理/归档，防膨胀 |
| `subscription_guard.sh` | 订阅配额保护（并发/频率/每日上限） |
| `checkpoint.sh` | Git 快照（委托前自动创建，失败可回滚） |
| `crash_recover.sh` | 崩溃断点续接（分析半成品，生成续接简报） |
| `env_snapshot.sh` | 环境漂移检测（pip/端口/crontab 前后对比） |
| `regression_test.sh` | 20 项回归测试（单元 + 全链路集成） |

## 状态枚举

`--status --json` 返回标准状态码：`RUNNING` / `COMPLETED` / `FAILED` / `TIMEOUT` / `INTERRUPTED` / `UNKNOWN`

历史任务可从 `call_log.jsonl` 恢复状态，最大限度减少 `UNKNOWN`。

## 状态管理

```bash
# 预览可清理文件
./scripts/state_cleanup.sh

# 清理 30 天前的过期文件
./scripts/state_cleanup.sh --execute

# 归档后清理
./scripts/state_cleanup.sh --archive --max-age 7
```

## 回归测试

```bash
# 全量回归（20 项）
./scripts/regression_test.sh

# 快速模式（跳过集成测试）
./scripts/regression_test.sh --quick

# 单项测试
./scripts/regression_test.sh --test selfcheck_json
```

## CI

GitHub Actions 自动在 push/PR 时运行 `regression_test.sh`，见 `.github/workflows/ci.yml`。

## 依赖

- bash >= 4.0
- python3
- git
- claude CLI（委托功能必需，自检和测试不需要）

## 详细文档

完整的铁律、工作流、权限处理等详见 [SKILL.md](SKILL.md)。

## 版本

当前版本：**2.2.0** — 详见 [CHANGELOG.md](CHANGELOG.md)
