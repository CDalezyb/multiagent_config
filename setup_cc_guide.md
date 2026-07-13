# setup_cc.sh — Claude Code 一键安装与配置指南

## 一、这个脚本是干什么的

`setup_cc.sh` 是一个**自动化脚本**，用于在新机器或容器中快速完成 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)（Anthropic 官方命令行 AI 编程助手）的安装、初始化与配置，并支持将 DeepSeek 配置为后端模型以降低使用成本。

该脚本主要完成三项工作：

- 🚀 **安装 Claude Code**：自动完成 Node.js → npm → Claude Code 整条安装链路
- 🔧 **同步配置**：将团队的全局规则与技能同步至 `~/.claude/`
- 💰 **切换 DeepSeek 后端**：以 DeepSeek 的价格使用 Claude Code 的体验

适用于新机器环境搭建、容器快速初始化、团队配置统一等场景。

### 前置条件

运行脚本前需确保系统已安装以下基础工具：

| 依赖 | 说明 |
|------|------|
| `curl` | 用于下载 Node.js 安装脚本（如系统尚无 Node.js） |
| `npm` | 用于安装 Claude Code 的包管理器 |
| `bash` | 脚本运行环境 |

> 若系统未安装 Node.js 或版本低于 18，脚本会**自动尝试安装** Node.js 20.x（优先通过 NodeSource apt 源，备选 nvm）。

---

## 二、怎么使用

### 2.1 安装 Claude Code

基本用法：安装/升级 Claude Code 并同步全局规则：

```bash
bash setup_cc.sh
```

执行该命令后，脚本将按以下顺序完成操作：

```
┌──────────────────────────────────────────────┐
│  ① 检查/安装 Node.js（要求版本 ≥ 18）          │
│  ② 配置 npm 用户级安装路径（避免使用 sudo）     │
│  ③ 通过 npm 安装 @anthropic-ai/claude-code    │
│  ④ 将 claude 命令添加至 PATH（写入 ~/.bashrc） │
│  ⑤ 将 rules/GLOBAL_RULES.md 同步到 ~/.claude/ │
│  ⑥ 完成                                        │
└──────────────────────────────────────────────┘
```

#### 安装全局技能

如需安装全局 skills（自定义技能），添加 `--install-skill` 参数：

```bash
bash setup_cc.sh --install-skill
```

此操作会将 `skills/` 目录下的所有技能（如 `get-datetime`）复制到 `~/.claude/skills/`，Claude Code 会自动识别。

#### 安装路径说明

| 内容 | 默认路径 | 说明 |
|------|----------|------|
| Claude Code 可执行文件 | `~/.local/bin/claude` | npm 全局安装 |
| 配置目录 | `~/.claude/` | 存放规则、技能、设置 |
| 全局规则文件 | `~/.claude/CLAUDE.md` | 由 `rules/GLOBAL_RULES.md` 生成 |
| 全局技能目录 | `~/.claude/skills/` | 由 `skills/` 目录复制而来 |

#### 通过环境变量自定义路径

```bash
# 自定义配置目录（默认 ~/.claude）
CLAUDE_CODE_HOME=/path/to/.claude bash setup_cc.sh

# 自定义二进制安装目录（默认 ~/.local/bin）
CC_BIN_DIR=/path/to/bin bash setup_cc.sh

# 仅同步配置，跳过 Claude Code 本体安装
SKIP_CC_INSTALL=1 bash setup_cc.sh --install-skill
```

#### 安装后验证

安装完成后，在**新终端**中运行：

```bash
claude --version
```

若显示版本号则安装成功。随后进入任意项目目录执行 `claude` 即可启动交互式会话。

---

### 2.2 配置 DeepSeek 后端

Claude Code 默认使用 Anthropic 官方 API，但直接使用 Anthropic 模型的成本较高。脚本提供了 `--use-deepseek` 参数以切换至 DeepSeek：

```bash
bash setup_cc.sh --use-deepseek
```

运行后会提示输入 DeepSeek API Key：

```
[INFO] Please enter your DeepSeek API Key:
```

输入 API Key（可在 [DeepSeek 开放平台](https://platform.deepseek.com/) 获取）并按回车即可。

#### 配置详情

脚本会在 `~/.claude/settings.json` 中写入如下配置：

```json
{
  "authMethod": "api-key",
  "hasCompletedOnboarding": true,
  "theme": "dark",
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "<你的 DeepSeek API Key>",
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-pro[1m]",
    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-pro[1m]",
    "CLAUDE_CODE_EFFORT_LEVEL": "max",
    "API_TIMEOUT_MS": "3000000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

配置项说明：

| 配置项 | 说明 |
|--------|------|
| `ANTHROPIC_AUTH_TOKEN` | DeepSeek API Key，作为认证令牌 |
| `ANTHROPIC_BASE_URL` | 将请求指向 DeepSeek 的 Anthropic 兼容端点 |
| `ANTHROPIC_MODEL` | 默认使用 `deepseek-v4-pro[1m]`，支持 1M 超长上下文 |
| `ANTHROPIC_DEFAULT_OPUS/SONNET/HAIKU_MODEL` | 将所有模型等级统一映射至 DeepSeek V4 Pro |
| `CLAUDE_CODE_SUBAGENT_MODEL` | 子代理（subagent）也使用同一模型 |
| `CLAUDE_CODE_EFFORT_LEVEL` | 设为 `max`，启用最大推理努力程度 |
| `API_TIMEOUT_MS` | 超时时间设为 3000 秒（50 分钟），避免长推理任务超时 |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | 禁用遥测等非必要网络流量 |

#### 组合使用

参数可组合使用：

```bash
bash setup_cc.sh --install-skill --use-deepseek
```

---

### 2.3 完整工作流示例

在一台全新的 Ubuntu 机器上从零搭建 Claude Code + DeepSeek 环境：

```bash
# 1. 进入 multiagent_config 目录
cd /path/to/multiagent_config

# 2. 一键完成安装、规则同步、技能安装及 DeepSeek 配置
bash setup_cc.sh --install-skill --use-deepseek

# 3. 根据提示输入 DeepSeek API Key

# 4. 打开新终端，验证安装
claude --version

# 5. 进入项目目录，开始使用
cd /path/to/your/project
claude
```

---

### 2.4 全局规则说明

脚本默认将 `rules/GLOBAL_RULES.md` 的内容同步至 `~/.claude/CLAUDE.md`，作为 Claude Code 的**全局指令**。当前规则包括：

- **语言**：默认使用中文回复
- **工作流**：先制定计划（/plan），再执行
- **Git**：不自动推送、不执行 force push、提交前检查 diff 和格式化
- **代码风格**：C/C++ 使用 Linux kernel 风格、Python 使用 PEP 8、Go 使用 gofmt 等

如需修改规则，编辑 `rules/GLOBAL_RULES.md` 后重新运行脚本即可生效。

---

### 2.5 常见问题

**Q: 提示 "npm is required" 怎么办？**

脚本依赖 npm 安装 Claude Code。若未安装 npm，可先安装 Node.js（npm 随 Node.js 一同安装）：

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
```

**Q: 安装后终端找不到 `claude` 命令？**

脚本已将 `~/.local/bin` 添加至 `~/.bashrc`，请打开新终端或执行 `source ~/.bashrc`。

**Q: 如何切换回 Anthropic 官方 API？**

编辑 `~/.claude/settings.json`，删除 `env` 中所有 DeepSeek 相关配置，重启 `claude` 即可。

**Q: 如何更新 Claude Code 版本？**

再次运行脚本即可，脚本会自动检测已安装版本并执行升级：

```bash
bash setup_cc.sh
```

**Q: 如何更换其他 DeepSeek 模型？**

修改 `~/.claude/settings.json` 中 `ANTHROPIC_MODEL` 的值（如 `deepseek-chat` 或 `deepseek-reasoner`），重启 Claude Code 即可。

---

## 三、为什么需要这样做

许多用户可能会问：既然 Claude Code 默认使用 Anthropic 官方 API，为什么还要配置 DeepSeek 作为后端？

核心原因在于**成本**。

### 3.1 价格对比

Anthropic 模型的单价较高，高频使用时费用累积迅速。DeepSeek 提供了兼容 Anthropic API 格式的端点，价格降低了约一个数量级。虽然模型能力相比 OpenAI Codex（GPT-5.5，当前编码能力最强的模型）仍有差距，但对于日常编码任务完全足够，适合大规模高频使用。

各模型价格横向对比（每百万 Token，单位 USD）：

| 模型 | 输入价格 | 输出价格 | 备注 |
|------|----------|----------|------|
| **DeepSeek V4 Pro** | $1.74 | $3.48 | 1M 上下文，兼容 Anthropic 格式 |
| DeepSeek V4 Flash | $0.14 | $0.28 | 轻量模型，适合简单任务 |
| OpenAI Codex（GPT-5.5） | $5.00 | $30.00 | 🏆 编码能力最强，价格最高 |
| OpenAI GPT-5.4 | $2.50 | $15.00 | 编码场景性价比之选 |
| OpenAI GPT-5.4 mini | $0.75 | $4.50 | 轻量编码任务 |
| Claude Opus 4.8 | $5.00 | $25.00 | Anthropic 旗舰模型 |
| Claude Sonnet 4.6 | $3.00 | $15.00 | Anthropic 中端模型 |
| Claude Haiku 4.5 | $1.00 | $5.00 | Anthropic 轻量模型 |

> 数据来源：[DeepSeek](https://api-docs.deepseek.com/quick_start/pricing)、[OpenAI](https://openai.com/api/pricing/)、[Anthropic](https://platform.claude.com/docs/en/docs/about-claude/pricing) 官方定价（2026 年 6 月）

### 3.2 实际成本估算

以一次典型编码会话为例（消耗约 50,000 输入 token + 15,000 输出 token）：

| 模型 | 单次会话成本 |
|------|-------------|
| **DeepSeek V4 Pro** | **≈ $0.14** |
| DeepSeek V4 Flash | ≈ $0.01 |
| OpenAI Codex（GPT-5.5） | ≈ $0.70 |
| OpenAI GPT-5.4 mini | ≈ $0.11 |
| Claude Sonnet 4.6 | ≈ $0.38 |
| Claude Opus 4.8 | ≈ $0.63 |

按每天 50 次会话、每月 30 天计算：

| 模型 | 月成本 |
|------|--------|
| **DeepSeek V4 Pro** | **≈ $210** |
| DeepSeek V4 Flash | ≈ $17 |
| OpenAI Codex（GPT-5.5） | ≈ $1,050 |
| OpenAI GPT-5.4 mini | ≈ $158 |
| Claude Sonnet 4.6 | ≈ $563 |
| Claude Opus 4.8 | ≈ $938 |

> 💡 DeepSeek V4 Pro 月成本约 $210，为 Codex 的 **1/5**、Opus 的 **1/4**。Flash 更是低至 $17/月（Codex 的 **1/60**），适合高频低难度任务。

### 3.3 结论

> 💡 **Codex 编码能力最强但成本也最高，DeepSeek 以更低的价格提供了满足日常使用的编码能力。** 对高频编码用户而言，DeepSeek 可显著降低使用成本。追求极致编码能力选 Codex，追求高性价比选 DeepSeek。
