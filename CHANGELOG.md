# Changelog

## [2.2.0] - 2026-04-07

### Added
- `state_cleanup.sh` — 状态目录清理与归档脚本，支持 dry-run / --execute / --archive / --max-age / --json
- `.gitignore` — 排除 `state/`、`.dev-delegate-status.md` 及常见临时产物
- `README.md` — 项目快速上手指南
- `CHANGELOG.md` — 版本变更记录
- `.github/workflows/ci.yml` — GitHub Actions CI，自动运行回归测试
- verify 报告新增结构化归档字段：`task_id` / `task_token` / `final_verdict` / `user_artifacts` / `internal_artifacts` / `verified_at`
- `--status --json` 支持从 `call_log.jsonl` 恢复历史任务状态，减少 UNKNOWN
- 回归测试新增 `state_cleanup` 和 `status_log_fallback` 测试用例

### Changed
- SKILL.md 升级到 v2.2.0，新增 JSON 模式、状态枚举、验证报告结构、状态管理等文档章节
- 文件结构文档更新，反映所有新增脚本和文件

## [2.1.0] - 2026-04-07

### Added
- `selfcheck.sh` — 版本与依赖自检脚本，支持 `--json` 输出
- `--json` 标志支持：`delegate_to_claude.sh --status`、`startup_check.sh`、`selfcheck.sh`
- 状态枚举：RUNNING / COMPLETED / FAILED / TIMEOUT / INTERRUPTED / UNKNOWN
- 回归测试增强至 20 项（含 selfcheck、JSON 输出、全链路集成测试）
- verify_delivery.sh 文件分类：区分用户交付文件 vs 技能内部状态文件
- 完成标记（done.json）优先于 PID 存活判断（H-08 修复）

### Changed
- CLI 能力探测结果缓存到 `.cli_caps_cache`，避免重复调用 `--help`
- subscription_guard.sh 支持环境变量覆盖配额参数

## [2.0.0] - 2026-04-06

### Added
- 完整的开发委托框架：前台/后台模式
- 5 条铁律：禁写、证据、锁定、诚实、分工
- 任务简报模板与质量校验
- Git checkpoint + 崩溃断点续接
- 环境漂移检测
- 订阅配额保护
- 实时进度监控
- 回归测试框架（11 项基础测试 + 4 项集成测试）
