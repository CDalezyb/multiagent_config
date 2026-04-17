# Global Rules

## 通用规则

- Always respond in Chinese unless explicitly asked otherwise
- Always start with /plan mode first, then proceed to build after planning is complete

## Git 操作规则

- 不要自动推送到远程仓库，除非用户明确要求
- 不要执行 git push/pull/clone 等远程操作，除非用户明确指示
- 使用 git status 查看当前状态前，不要执行任何 git 操作
- 提交前先检查 git diff 确保修改正确

## 编程风格规则

- C/C++ 代码遵循 Linux kernel 风格（使用 tab 缩进）
- Python 代码遵循 PEP 8 风格
- JavaScript/TypeScript 代码遵循项目自带的 ESLint 配置
- Go 代码遵循 gofmt 风格
- 代码审查：检查潜在的 bug、安全问题、性能问题
- 为新代码编写测试用例