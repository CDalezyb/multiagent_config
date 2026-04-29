# Multiagent Config

自动化配置 Codex / OpenCode / Cursor 的脚本集合，用于在新机器或容器中快速完成工具安装和全局配置同步。

## 目录结构

```text
multiagent_config/
├── setup_codex.sh        # Codex 安装和可选配置同步脚本
├── setup_opencode.sh     # OpenCode 配置脚本
├── setup_cursor.sh       # Cursor 配置脚本
├── rules/
│   └── GLOBAL_RULES.md   # 全局规则
└── skills/
    └── get-datetime/
        └── SKILL.md      # 示例技能
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

## OpenCode / Cursor

仓库中仍保留 OpenCode 和 Cursor 的配置脚本：

```bash
bash setup_opencode.sh
bash setup_cursor.sh
```
