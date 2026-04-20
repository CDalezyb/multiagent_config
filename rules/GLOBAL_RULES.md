# Global Rules

## 通用规则

- Always respond in Chinese unless explicitly asked otherwise
- Always start with /plan mode first, then proceed to build after planning is complete

## Git 操作规则

- 不要自动推送到远程仓库，除非用户明确要求
- 不要执行 git push/pull/clone 等远程操作，除非用户明确指示
- 使用 git status 查看当前状态前，不要执行任何 git 操作
- 提交前先检查 git diff 确保修改正确
- 提交前如项目有代码 format 配置（如 .clang-format、.prettierrc、.eslintrc 等），则执行 format
- 默认使用 git push 推送代码
- 禁止使用 force 方式 push 代码（如 git push --force），除非用户明确要求
- 如果用户明确要求使用 force push，默认使用 git push --force-with-lease

## 编程风格规则

- 首先检测项目根目录（或上级、上上级目录）是否存在编程风格规则文件（如 `.clang-format`、`.prettierrc`、`pyproject.toml`、`go.sum` 等），如有则遵循项目现有规则
- 如无项目规则，则使用以下默认规则：
  - C/C++ 代码遵循 Linux kernel 风格（使用 tab 缩进）
  - Python 代码遵循 PEP 8 风格
  - JavaScript/TypeScript 代码遵循项目自带的 ESLint 配置
  - Go 代码遵循 gofmt 风格
- 代码审查：检查潜在的 bug、安全问题、性能问题
- 为新代码编写测试用例