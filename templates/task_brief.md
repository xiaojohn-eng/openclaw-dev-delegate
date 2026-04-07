# 任务简报：{任务ID}

> 此模板为 dev-delegate 技能的标准格式，所有 6 个字段必须填写（≥20字），否则不允许发起 Claude Code 调用。

## 1. 背景
{为什么做这个任务？解决什么问题？业务上下文是什么？}

## 2. 目标
{做到什么程度算完成？列出可量化的验收标准。}

验收标准：
- [ ] {标准 1}
- [ ] {标准 2}
- [ ] {标准 3}

## 3. 约束
{技术限制、业务边界、不能做什么、环境限制。}

- 不可以：{xxx}
- 必须遵守：{xxx}
- 环境限制：{xxx}

## 4. 输入
{Claude Code 需要读取的现有文件路径列表，以及每个文件的作用。}

| 文件路径 | 作用 |
|---------|------|
| `/root/project/xxx.py` | {说明} |
| `/root/project/yyy.md` | {说明} |

## 5. 输出
{期望 Claude Code 产出/修改的文件列表，以及每个文件应包含的内容。}

| 文件路径 | 预期内容 |
|---------|---------|
| `/root/project/new_file.py` | {说明} |
| `/root/project/modified.py` | {修改什么} |

## 6. 依赖
{环境要求、前置条件、已有代码状态、需要预装的工具。}

- Python 版本：{xxx}
- 已安装的包：{xxx}
- 数据库状态：{xxx}
- 前置任务：{无 / task_xxx 已完成}

## 7. 自动验收命令（可选但强烈建议）

> verify_delivery.sh 会自动执行以下命令，每条返回 0 视为通过。
> 这些命令用于验证 Claude Code 的产出是否**真正可用**，不仅仅是"文件存在"。

```bash
python3 -m pytest tests/ -q
python3 -c "from core.modules.xxx import XxxService; print('OK')"
curl -sf http://localhost:8011/health
```
