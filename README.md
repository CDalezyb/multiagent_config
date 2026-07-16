# Multiagent Config

自动化配置 Codex / OpenCode / Cursor / Claude Code 的脚本集合，用于在新机器或容器中快速完成工具安装和全局配置同步。

## 目录结构

```text
multiagent_config/
├── setup_codex.sh              # Codex 安装和可选配置同步脚本
├── setup_codex_deepseek.sh     # Codex 接入 DeepSeek（Moon Bridge 方案）
├── setup_opencode.sh           # OpenCode 配置脚本
├── setup_cursor.sh             # Cursor 配置脚本
├── setup_cc.sh                 # Claude Code (claude) 安装和配置同步脚本
├── rules/
│   └── GLOBAL_RULES.md         # 全局规则
└── skills/
    └── get-datetime/
        └── SKILL.md            # 示例技能
```

## Codex 使用方法

默认只安装或更新 Codex，不复制 rules 和 skills。这个模式适合容器中已经通过 volume 映射宿主机 Codex 目录的场景。

```bash
bash setup_codex.sh
```

如果需要额外同步全局技能：

```bash
bash setup_codex.sh --install-skill
```

如果需要额外同步全局规则：

```bash
bash setup_codex.sh --install-rule
```

如果两者都需要同步：

```bash
bash setup_codex.sh --install-skill --install-rule
```

查看参数说明：

```bash
bash setup_codex.sh --help
```

## Codex 相关环境变量

可以通过环境变量调整安装位置：

```bash
CODEX_HOME=/path/to/.codex bash setup_codex.sh
CODEX_BIN_DIR=/path/to/bin bash setup_codex.sh
```

如果只想测试 rules / skills 同步逻辑，不执行 Codex 安装：

```bash
SKIP_CODEX_INSTALL=1 bash setup_codex.sh --install-skill --install-rule
```

## 容器映射建议

如果宿主机已有 Codex 配置目录，可以在启动容器时映射进去：

```bash
docker run -it \
  -v "$HOME/.codex:/root/.codex" \
  <image> \
  /bin/bash
```

这样容器内执行：

```bash
bash setup_codex.sh
```

只会安装或更新 Codex，本地 rules 和 skills 会直接使用映射进来的宿主机配置。

## 自定义规则

修改 `rules/GLOBAL_RULES.md` 后，执行：

```bash
bash setup_codex.sh --install-rule
```

脚本会生成或覆盖：

```text
$CODEX_HOME/AGENTS.md
```

默认路径为：

```text
~/.codex/AGENTS.md
```

## 自定义技能

在 `skills/` 目录下添加新的技能文件夹，每个技能需要包含 `SKILL.md` 文件。

示例结构：

```text
skills/
└── my-skill/
    └── SKILL.md
```

更新技能：

```bash
bash setup_codex.sh --install-skill
```

## OpenCode / Cursor / Claude Code

仓库中仍保留 OpenCode、Cursor 和 Claude Code 的配置脚本：

```bash
bash setup_opencode.sh
bash setup_cursor.sh
bash setup_cc.sh
```

## Claude Code 使用方法

安装或更新 Claude Code v2.1.153：

```bash
bash setup_cc.sh
```

配置 DeepSeek 后端（按官方文档写入 `~/.claude/settings.json`）：

```bash
bash setup_cc.sh --use-deepseek
```

脚本会提示输入 DeepSeek API Key，然后写入 `~/.claude/settings.json`，包含 `authMethod`、`hasCompletedOnboarding` 以及完整的 `env` 配置。

同步 rules / skills：

```bash
bash setup_cc.sh --install-rule
bash setup_cc.sh --install-skill
bash setup_cc.sh --install-rule --install-skill
```

安装并配置 DeepSeek：

```bash
bash setup_cc.sh --use-deepseek
```

查看参数说明：

```bash
bash setup_cc.sh --help
```

## Claude Code 相关环境变量

```bash
CLAUDE_CODE_HOME=/path/to/.claude bash setup_cc.sh
CC_BIN_DIR=/path/to/bin bash setup_cc.sh
SKIP_CC_INSTALL=1 bash setup_cc.sh --use-deepseek
```

## Codex + DeepSeek 接入方法

通过 Moon Bridge 本地转发层，将 Codex 的 OpenAI Responses API 请求转发到 DeepSeek，使 DeepSeek 成为 Codex 可切换的模型选项。

> 参考文档：https://cloud.tencent.com/developer/article/2671457

### 架构

```text
Codex CLI / codex.app
     ↓
读取 ~/.codex/config.toml（含 deepseek provider）
     ↓
请求 http://127.0.0.1:<auto-port>/v1/responses
     ↓
Moon Bridge（本地协议转发层）
     ↓
DeepSeek API（https://api.deepseek.com/anthropic）
```

### 快速开始

一键启用 DeepSeek（首次使用会提示输入 API Key）：

```bash
bash setup_codex_deepseek.sh --use-deepseek
```

切换回 OpenAI 默认后端：

```bash
bash setup_codex_deepseek.sh --use-openai
```

查看当前状态：

```bash
bash setup_codex_deepseek.sh --status
```

### DeepSeek 作为同级模型选项（双文件 + 软连接）

采用**双文件 + 软连接**方案，不修改原配置文件，切换零风险：

```text
~/.codex/
├── config.toml            → 软连接 → config_openai.toml 或 config_deepseek.toml
├── config_openai.toml     → 用户原始配置（永不被修改）
├── config_deepseek.toml   → 基于 openai 配置 + deepseek provider 块
└── models_catalog.json    → 模型能力描述（Codex UI 展示用）
```

**原理：**
- 首次 `--use-deepseek` 时：`config.toml` 重命名为 `config_openai.toml`，创建软连接，生成 `config_deepseek.toml`
- 切换只需改软连接目标，不动任何配置文件内容
- `config_openai.toml` 完整保留用户的 `model`、`model_reasoning_effort`、`project trusts`、`notices` 等所有字段
- 切回 OpenAI 时 `model = "gpt-5.4"` 原样恢复，不会丢失

```bash
# 切换到 DeepSeek（软连接 → config_deepseek.toml）
bash setup_codex_deepseek.sh --use-deepseek

# 切换回 OpenAI（软连接 → config_openai.toml）
bash setup_codex_deepseek.sh --use-openai
```

> 软连接在 volume 挂载的容器中同样生效（路径在同一挂载目录内）。

### 多容器 / 宿主机共用

由于容器使用 `--network=host`（参考 `env_config/config_docker_run.sh`），容器与宿主机共享网络命名空间。Moon Bridge 只需在宿主机运行一次：

```text
宿主机                          容器 A              容器 B
───────                        ───────             ───────
Moon Bridge :<auto-port>  ←────────  codex CLI           codex CLI
~/.codex/config.toml  ────────  volume/共享        volume/共享
```

**推荐流程：**

```bash
# 1) 宿主机：一键启用（启动 Moon Bridge + 配置 Codex）
bash setup_codex_deepseek.sh --use-deepseek

# 2) 容器内：复用宿主机 Moon Bridge，仅配置 Codex 侧
bash setup_codex_deepseek.sh --use-deepseek \
  --moonbridge-addr http://127.0.0.1:<port>/v1
```

或直接在宿主机完成配置，容器通过 volume 挂载 `~/.codex` 目录自动共享。

### 参数说明

```bash
bash setup_codex_deepseek.sh --help
```

| 参数 | 说明 |
|------|------|
| `--use-deepseek` | 启用 DeepSeek（启动 Moon Bridge + 配置 Codex） |
| `--use-openai` | 切换回 OpenAI 默认后端 |
| `--status` | 查看 Codex 和 Moon Bridge 当前状态 |
| `--setup-moonbridge` | 仅准备 Moon Bridge（克隆/构建 + 生成配置） |
| `--start-moonbridge` | 仅启动 Moon Bridge 服务 |
| `--stop-moonbridge` | 仅停止 Moon Bridge 服务 |
| `--moonbridge-addr URL` | 指定 Moon Bridge 地址（默认自动探测可用端口，范围 49152-65535） |
| `--moonbridge-bin PATH` | 指定 Moon Bridge 二进制路径（跳过构建） |
| `--api-key KEY` | 直接提供 DeepSeek API Key |
| `--api-key-file PATH` | 从文件读取 API Key |
| `--force-reconfigure` | 强制重新生成 Moon Bridge 配置 |

### 环境变量

```bash
CODEX_HOME=/path/to/.codex bash setup_codex_deepseek.sh --use-deepseek
DEEPSEEK_API_KEY=sk-xxx bash setup_codex_deepseek.sh --use-deepseek
```

### 前置条件

- **Codex CLI 已安装**（通过 `setup_codex.sh` 安装）
- **Go 1.25+**（用于构建 Moon Bridge；或通过 `--moonbridge-bin` 指定已有二进制）
- **DeepSeek API Key**（在 https://platform.deepseek.com/api_keys 获取）

### 验证链路

```bash
# 查看 Moon Bridge 暴露的模型
curl http://127.0.0.1:<port>/v1/models

# 发送测试请求
curl http://127.0.0.1:<port>/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"moonbridge","input":"你好","max_output_tokens":100}'
```
