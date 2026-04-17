# OpenCode 容器配置脚本

自动化配置 OpenCode 环境的脚本，支持在新容器中快速完成安装、规则和技能设置。

## 目录结构

```
config_opencode/
├── setup_opencode.sh     # 主脚本
├── rules/
│   └── GLOBAL_RULES.md   # 全局规则
└── skills/
    └── get-datetime/     # 示例技能
        └── SKILL.md
```

## 使用方法

### 1. 克隆仓库

```bash
git clone git@github.com:CDalezyb/config_opencode.git
cd config_opencode
```

### 2. 运行脚本

```bash
./setup_opencode.sh
```

### 3. 设置 API Key（可选）

```bash
# 临时设置
export OPENAI_API_KEY=sk-your-key-here

# 持久化（自动添加到 ~/.bashrc 或 ~/.zshrc）
echo "export OPENAI_API_KEY=sk-your-key" >> ~/.bashrc
source ~/.bashrc
```

### 4. 启动 OpenCode

```bash
opencode
```

## 功能

- [x] 自动安装 OpenCode
- [x] 配置全局规则 (AGENTS.md)
- [x] 配置全局技能 (Skills)

## 自定义规则

修改 `rules/GLOBAL_RULES.md` 后重新运行脚本即可生效。

## 自定义技能

在 `skills/` 目录下添加新的技能文件夹，每个技能需要包含 `SKILL.md` 文件。

技能格式：
```markdown
---
name: 技能名称
description: 技能描述
---

# 技能说明

技能使用说明...
```

## 获取 OpenAI API Key

1. 访问 https://platform.openai.com/
2. 登录账号
3. 进入 API Keys: https://platform.openai.com/api-keys
4. 创建新的密钥