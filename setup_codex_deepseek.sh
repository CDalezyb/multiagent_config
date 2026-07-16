#!/bin/bash
# ============================================================================
# setup_codex_deepseek.sh — 将 DeepSeek 接入 Codex 模型列表
# ============================================================================
# 方案：通过 Moon Bridge 做本地转发层，将 Codex 的 OpenAI Responses API 请求
#       转发到 DeepSeek API，使 DeepSeek 成为 Codex 可用的模型选项。
#
# 配置管理：双文件 + 软连接方案
#   config.toml          → 软连接 → config_openai.toml 或 config_deepseek.toml
#   config_openai.toml   → 用户原始配置（永不被修改）
#   config_deepseek.toml → 基于 openai 配置 + deepseek provider 块
#   切换只改一个软连接，不丢失任何原有字段（model, project trusts, notices 等）
#   软连接在 volume 挂载的容器中同样生效（路径在同一挂载目录内）
#
# 参考：https://cloud.tencent.com/developer/article/2671457
#       https://github.com/ZhiYi-R/moon-bridge
#
# 架构：
#   Codex CLI / codex.app
#        ↓
#   读取 ~/.codex/config.toml（含 deepseek provider）
#        ↓
#   请求 http://127.0.0.1:38440/v1/responses
#        ↓
#   Moon Bridge（本地转发层）
#        ↓
#   DeepSeek API（https://api.deepseek.com/anthropic）
#
# 多容器 / 宿主机支持：
#   - 宿主机使用 --network=host 启动容器，共享网络命名空间
#   - Moon Bridge 在宿主机运行一次，所有容器 + 宿主机共用
#   - Codex config.toml 和 models_catalog.json 通过 volume 或共享目录同步
# ============================================================================

set -euo pipefail

# ======================== 颜色 & 日志 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }

# ======================== 路径 & 常量 ========================
# 安全端口范围：IANA 动态/私有端口 49152-65535，不会被系统服务占用
MOON_BRIDGE_PORT_MIN=49152
MOON_BRIDGE_PORT_MAX=65535
DEEPSEEK_API_BASE="https://api.deepseek.com/anthropic"
DEEPSEEK_MODEL_NAME="deepseek-v4-pro"
DEEPSEEK_PROVIDER_NAME="deepseek"

script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# Moon Bridge 源码（本地 submodule，路径相对于 multiagent_config）
moonbridge_repo_dir() {
    printf '%s/moon-bridge' "$(script_dir)"
}

codex_home() {
    if [ -n "${CODEX_HOME:-}" ]; then
        printf '%s\n' "$CODEX_HOME"
    else
        printf '%s\n' "${HOME}/.codex"
    fi
}

moonbridge_dir() {
    printf '%s/moonbridge' "$(codex_home)"
}

moonbridge_bin() {
    printf '%s/bridge' "$(moonbridge_dir)"
}

moonbridge_config() {
    printf '%s/config.yml' "$(moonbridge_dir)"
}

# API Key 持久化文件（存在 ~/.codex/ 中，可通过 volume 共享给容器）
deepseek_apikey_file() {
    printf '%s/.deepseek_apikey' "$(codex_home)"
}

moonbridge_pid_file() {
    # PID 文件放在 /tmp，避免多容器共享 CODEX_HOME 时冲突
    # 使用 CODEX_HOME 的 hash 区分不同 codex 实例
    local home_hash
    home_hash=$(printf '%s' "$(codex_home)" | md5sum | cut -c1-8)
    printf '/tmp/codex-moonbridge-%s.pid' "$home_hash"
}

moonbridge_log() {
    printf '%s/moonbridge.log' "$(moonbridge_dir)"
}

moonbridge_port_file() {
    printf '%s/port' "$(moonbridge_dir)"
}

# 探测可用端口（范围 49152-65535），找到后持久化保存
# 如果已保存过端口且仍在监听，复用；否则重新探测
find_available_port() {
    local port_file saved_port
    port_file="$(moonbridge_port_file)"

    # 已有保存的端口且 Moon Bridge 正在该端口运行 → 复用
    if [ -f "$port_file" ]; then
        saved_port=$(cat "$port_file" 2>/dev/null || true)
        if [ -n "$saved_port" ]; then
            if check_command ss; then
                ss -tlnp 2>/dev/null | grep -q ":${saved_port} " && printf '%s' "$saved_port" && return 0
            elif check_command netstat; then
                netstat -tlnp 2>/dev/null | grep -q ":${saved_port} " && printf '%s' "$saved_port" && return 0
            fi
            # 端口文件存在但未监听 → 优先重用这个端口号
            printf '%s' "$saved_port"
            return 0
        fi
    fi

    # 探测新端口
    local port
    for port in $(seq "$MOON_BRIDGE_PORT_MIN" "$MOON_BRIDGE_PORT_MAX" | shuf); do
        if ! check_port_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done

    print_error "无法找到可用端口（范围 ${MOON_BRIDGE_PORT_MIN}-${MOON_BRIDGE_PORT_MAX}）"
    return 1
}

check_port_in_use() {
    local port="$1"
    if check_command ss; then
        ss -tln 2>/dev/null | grep -q ":${port} " && return 0
    elif check_command netstat; then
        netstat -tln 2>/dev/null | grep -q ":${port} " && return 0
    fi
    return 1
}

# 获取/设置 Moon Bridge 端口（自动探测 + 持久化）
moonbridge_port() {
    local port
    port=$(find_available_port) || return 1

    # 持久化保存
    local port_file
    port_file="$(moonbridge_port_file)"
    if [ ! -f "$port_file" ] || [ "$(cat "$port_file" 2>/dev/null)" != "$port" ]; then
        mkdir -p "$(dirname "$port_file")"
        printf '%s' "$port" > "$port_file"
    fi
    printf '%s' "$port"
}

# 获取 Moon Bridge base URL（供 Codex config.toml 使用）
moonbridge_base_url() {
    if [ -n "${MOONBRIDGE_ADDR:-}" ]; then
        printf '%s' "$MOONBRIDGE_ADDR"
    else
        printf 'http://127.0.0.1:%s/v1' "$(moonbridge_port)"
    fi
}

codex_config_toml() {
    printf '%s/config.toml' "$(codex_home)"
}

config_openai_toml() {
    printf '%s/config_openai.toml' "$(codex_home)"
}

config_deepseek_toml() {
    printf '%s/config_deepseek.toml' "$(codex_home)"
}

codex_models_catalog() {
    printf '%s/models_catalog.json' "$(codex_home)"
}

# ======================== 工具函数 ========================
check_command() {
    command -v "$1" >/dev/null 2>&1
}

is_moonbridge_running() {
    local pid_file
    pid_file="$(moonbridge_pid_file)"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # 兜底：检查已保存端口是否被占用
    local port_file saved_port
    port_file="$(moonbridge_port_file)"
    if [ -f "$port_file" ]; then
        saved_port=$(cat "$port_file" 2>/dev/null || true)
        if [ -n "$saved_port" ]; then
            if check_command ss; then
                ss -tlnp 2>/dev/null | grep -q ":${saved_port} " && return 0
            elif check_command netstat; then
                netstat -tlnp 2>/dev/null | grep -q ":${saved_port} " && return 0
            fi
        fi
    fi
    return 1
}

get_moonbridge_pid() {
    local pid_file
    pid_file="$(moonbridge_pid_file)"
    if [ -f "$pid_file" ]; then
        cat "$pid_file" 2>/dev/null || true
    fi
}

# ======================== Moon Bridge 管理 ========================
ensure_moonbridge_binary() {
    local bin_path
    bin_path="$(moonbridge_bin)"

    # 1) 已通过 --moonbridge-bin 指定
    if [ -n "${MOONBRIDGE_BIN_OVERRIDE:-}" ]; then
        if [ -x "$MOONBRIDGE_BIN_OVERRIDE" ]; then
            print_info "使用指定的 Moon Bridge: ${MOONBRIDGE_BIN_OVERRIDE}"
            return 0
        fi
        print_error "指定的 Moon Bridge 不可执行: ${MOONBRIDGE_BIN_OVERRIDE}"
        return 1
    fi

    # 2) 已缓存的二进制
    if [ -x "$bin_path" ]; then
        print_info "Moon Bridge 二进制已存在: ${bin_path}"
        return 0
    fi

    # 3) 系统 PATH 中已有
    if check_command moonbridge; then
        print_info "系统 PATH 中找到 moonbridge: $(command -v moonbridge)"
        mkdir -p "$(moonbridge_dir)"
        ln -sf "$(command -v moonbridge)" "$bin_path"
        return 0
    fi

    # 4) 从本地 submodule 构建（需要 Go）
    print_step "从本地 submodule 构建 Moon Bridge..."
    if ! check_command go; then
        cat <<'GO_HELP'

========================================
  Moon Bridge 需要 Go 1.25+ 来构建。
  请选择以下方式之一：

  方式 A — 安装 Go 后重新运行本脚本：
    apt-get update && apt-get install -y golang-go
    # 或下载: https://go.dev/dl/

  方式 B — 手动指定 Moon Bridge 二进制路径：
    bash setup_codex_deepseek.sh --moonbridge-bin /path/to/moonbridge
========================================

GO_HELP
        return 1
    fi

    local go_version repo_dir go_major go_minor
    go_version=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    go_major=$(echo "$go_version" | cut -d. -f1)
    go_minor=$(echo "$go_version" | cut -d. -f2)
    print_info "检测到 Go ${go_version}"

    # Moon Bridge 需要 Go >= 1.25
    if [ "$go_major" -lt 1 ] 2>/dev/null || { [ "$go_major" -eq 1 ] && [ "$go_minor" -lt 25 ]; }; then
        print_error "Moon Bridge 需要 Go >= 1.25，当前版本: ${go_version}"
        print_info "请升级 Go 后重试，或使用 --moonbridge-bin 指定预编译二进制"
        return 1
    fi

    repo_dir="$(moonbridge_repo_dir)"

    if [ ! -d "$repo_dir" ]; then
        print_error "Moon Bridge submodule 不存在: ${repo_dir}"
        print_info "请确保已初始化 git submodule:"
        print_info "  cd $(script_dir) && git submodule update --init"
        return 1
    fi

    print_info "构建 Moon Bridge（源码: ${repo_dir}）..."
    mkdir -p "$(dirname "$bin_path")"

    # Go 1.25 在父目录存在 .git 时可能触发 VCS workspace 检测，
    # 导致即使在 moon-bridge 目录内也报 "cannot find main module"。
    # 兜底方案：临时写一个 go.work 覆盖自动检测。
    local need_workfile=0
    cd "$repo_dir"
    if ! go build -o "$bin_path" ./cmd/moonbridge 2>/dev/null; then
        need_workfile=1
    fi
    cd - >/dev/null

    if [ "$need_workfile" -eq 1 ]; then
        print_warn "直接构建失败，尝试用 go.work 覆盖 VCS 检测..."
        printf 'go 1.25.0\n\nuse .\n' > "$repo_dir/go.work"
        cd "$repo_dir"
        if ! go build -o "$bin_path" ./cmd/moonbridge; then
            rm -f "$repo_dir/go.work"
            cd - >/dev/null
            print_error "go build 失败，请检查 Go 版本和 moon-bridge 源码"
            return 1
        fi
        rm -f "$repo_dir/go.work"
        cd - >/dev/null
    fi
    chmod +x "$bin_path"
    print_info "Moon Bridge 构建成功: ${bin_path}"
}

generate_moonbridge_config() {
    local config_file api_key apikey_store
    config_file="$(moonbridge_config)"
    apikey_store="$(deepseek_apikey_file)"
    api_key="${DEEPSEEK_API_KEY:-}"

    # 如果配置文件已存在且未强制重新生成，则跳过
    if [ -f "$config_file" ] && [ "${FORCE_RECONFIGURE:-0}" != "1" ]; then
        print_info "Moon Bridge 配置已存在: ${config_file}"
        return 0
    fi

    # === API Key 获取（支持持久化，二次切换无需重新输入）===
    # 优先级: 命令行 --api-key > 环境变量 DEEPSEEK_API_KEY > 文件 DEEPSEEK_API_KEY_FILE > 持久化存储 > 交互输入

    # 1) 从命令行 --api-key 或环境变量传入（已在上面处理）
    # 2) 从 DEEPSEEK_API_KEY_FILE 文件读取
    if [ -z "$api_key" ]; then
        if [ -n "${DEEPSEEK_API_KEY_FILE:-}" ] && [ -f "$DEEPSEEK_API_KEY_FILE" ]; then
            api_key=$(cat "$DEEPSEEK_API_KEY_FILE" | tr -d '[:space:]')
            print_info "从文件读取 DeepSeek API Key: ${DEEPSEEK_API_KEY_FILE}"
        fi
    fi

    # 3) 从持久化存储读取（上次成功保存的 key）
    if [ -z "$api_key" ] && [ -f "$apikey_store" ]; then
        api_key=$(cat "$apikey_store" | tr -d '[:space:]')
        if [ -n "$api_key" ]; then
            print_info "使用已保存的 DeepSeek API Key（${apikey_store}）"
        fi
    fi

    # 4) 交互式输入
    if [ -z "$api_key" ]; then
        echo ""
        print_info "请输入 DeepSeek API Key（可在 https://platform.deepseek.com/api_keys 获取）："
        print_info "（输入后会自动保存，下次切换无需再次输入）"
        read -r -s api_key
        echo ""
        if [ -z "$api_key" ]; then
            print_error "API Key 不能为空"
            return 1
        fi
    fi

    # 持久化保存 API Key（仅当是新输入的或来源不是持久化存储时）
    if [ ! -f "$apikey_store" ] || [ "$(cat "$apikey_store" | tr -d '[:space:]')" != "$api_key" ]; then
        printf '%s' "$api_key" > "$apikey_store"
        chmod 600 "$apikey_store"
        print_info "API Key 已保存至: ${apikey_store}"
    fi

    mkdir -p "$(moonbridge_dir)"

    cat > "$config_file" <<CONFIG_EOF
# Moon Bridge 配置 — 由 setup_codex_deepseek.sh 自动生成
# 参考: https://cloud.tencent.com/developer/article/2671457

mode: "Transform"

server:
  addr: "127.0.0.1:$(moonbridge_port)"

models:
  ${DEEPSEEK_MODEL_NAME}:
    context_window: 1000000
    max_output_tokens: 384000
    extensions:
      deepseek_v4:
        enabled: true
    default_reasoning_level: "high"
    supported_reasoning_levels:
      - effort: "high"
        description: "High reasoning effort"
      - effort: "xhigh"
        description: "Extra high reasoning effort"
    supports_reasoning_summaries: true
    default_reasoning_summary: "auto"

providers:
  deepseek:
    base_url: "${DEEPSEEK_API_BASE}"
    api_key: "${api_key}"
    user_agent: "moonbridge/1.0"
    web_search:
      support: "auto"
    offers:
      - model: ${DEEPSEEK_MODEL_NAME}
        pricing:
          input_price: 2
          output_price: 8
          cache_write_price: 1
          cache_read_price: 0.2

routes:
  moonbridge:
    model: ${DEEPSEEK_MODEL_NAME}
    provider: deepseek
CONFIG_EOF

    chmod 600 "$config_file"
    print_info "Moon Bridge 配置已生成: ${config_file}"
}

start_moonbridge() {
    local bin_path config_file pid_file log_file
    bin_path="$(moonbridge_bin)"
    config_file="$(moonbridge_config)"
    pid_file="$(moonbridge_pid_file)"
    log_file="$(moonbridge_log)"

    if is_moonbridge_running; then
        print_warn "Moon Bridge 已在运行中（PID: $(get_moonbridge_pid)）"
        return 0
    fi

    if [ ! -x "$bin_path" ]; then
        print_error "Moon Bridge 二进制不存在: ${bin_path}"
        print_info "请先运行: bash setup_codex_deepseek.sh --setup-moonbridge"
        return 1
    fi

    if [ ! -f "$config_file" ]; then
        print_error "Moon Bridge 配置文件不存在: ${config_file}"
        return 1
    fi

    local port
    port="$(moonbridge_port)"
    print_info "启动 Moon Bridge（端口 ${port}）..."
    nohup "$bin_path" --config "$config_file" > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"

    # 等待启动
    local waited=0
    while [ $waited -lt 10 ]; do
        sleep 0.5
        waited=$((waited + 1))
        if is_moonbridge_running; then
            print_info "Moon Bridge 启动成功（PID: $pid, 端口: $(moonbridge_port)）"
            print_info "日志文件: ${log_file}"
            return 0
        fi
    done

    print_error "Moon Bridge 启动超时，请检查日志: ${log_file}"
    print_error "最近日志:"
    tail -20 "$log_file" 2>/dev/null || true
    return 1
}

stop_moonbridge() {
    local pid_file pid
    pid_file="$(moonbridge_pid_file)"

    if ! is_moonbridge_running; then
        print_info "Moon Bridge 未在运行"
        rm -f "$pid_file"
        return 0
    fi

    pid=$(get_moonbridge_pid)
    print_info "停止 Moon Bridge（PID: $pid）..."

    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        # 等待优雅退出
        local waited=0
        while [ $waited -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 0.3
            waited=$((waited + 1))
        done
        # 强制终止
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$pid_file"
    print_info "Moon Bridge 已停止"
}

# ======================== Codex 配置管理（双文件 + 软连接） ========================
# 方案：
#   config.toml          → 软连接，指向 config_openai.toml 或 config_deepseek.toml
#   config_openai.toml   → 用户原始配置（从不动它）
#   config_deepseek.toml → 基于 openai 配置 + deepseek provider 块
#
# 切换只需改软连接，不丢失任何原有配置字段（model、project trusts、notices 等）。
# 软连接在 volume 挂载的容器中同样生效（路径在同一挂载目录内）。

# 检查 config.toml 是否为软连接
is_symlink_config() {
    [ -L "$(codex_config_toml)" ]
}

# 解析 config.toml 指向哪个配置文件
resolve_active_config() {
    local cfg
    cfg="$(codex_config_toml)"
    if [ -L "$cfg" ]; then
        readlink -f "$cfg"
    elif [ -f "$cfg" ]; then
        printf '%s\n' "$cfg"
    else
        printf ''
    fi
}

# 首次迁移：config.toml 是实体文件 → 重命名为 config_openai.toml → 创建软连接
migrate_to_symlink() {
    local cfg openai_cfg deepseek_cfg
    cfg="$(codex_config_toml)"
    openai_cfg="$(config_openai_toml)"
    deepseek_cfg="$(config_deepseek_toml)"

    # 已经是软连接 → 无需迁移
    if [ -L "$cfg" ]; then
        print_info "config.toml 已是软连接，跳过迁移"
        return 0
    fi

    # config.toml 不存在 → 创建空的 openai 配置
    if [ ! -f "$cfg" ]; then
        print_info "config.toml 不存在，创建默认 OpenAI 配置"
        mkdir -p "$(codex_home)"
        touch "$openai_cfg"
        cd "$(codex_home)"
        ln -sf "$(basename "$openai_cfg")" config.toml
        cd - >/dev/null
        print_info "已创建: config.toml -> $(basename "$openai_cfg")"
        return 0
    fi

    # config.toml 是实体文件 → 迁移
    print_info "迁移 config.toml 为双文件+软连接方案..."

    # 如果 config_openai.toml 已存在，说明之前迁移过，先备份当前 config.toml
    if [ -f "$openai_cfg" ]; then
        print_warn "config_openai.toml 已存在，将当前 config.toml 覆盖写入"
    fi

    cp "$cfg" "$openai_cfg"
    cd "$(codex_home)"
    rm -f config.toml
    ln -sf "$(basename "$openai_cfg")" config.toml
    cd - >/dev/null
    print_info "迁移完成: config.toml -> $(basename "$openai_cfg")"
    print_info "原配置已保存为: ${openai_cfg}"
}

# 生成 deepseek provider 的 TOML 配置块
generate_deepseek_provider_toml() {
    local moonbridge_addr
    moonbridge_addr="$(moonbridge_base_url)"

    cat <<TOML_EOF

# === DeepSeek Provider（由 setup_codex_deepseek.sh 管理） ===
[model_providers.${DEEPSEEK_PROVIDER_NAME}]
name = "${DEEPSEEK_PROVIDER_NAME}"
base_url = "${moonbridge_addr}"
wire_api = "responses"
TOML_EOF
}

# 生成 deepseek 模型属性的 TOML 配置块
generate_deepseek_properties_toml() {
    cat <<TOML_EOF

# === DeepSeek 模型属性（由 setup_codex_deepseek.sh 管理） ===
[model_properties."${DEEPSEEK_MODEL_NAME}"]
context_window = 262144
max_context_window = 1048576
supports_parallel_tool_calls = true
supports_reasoning_summaries = true
input_modalities = ["text"]
TOML_EOF
}

# 检查文件是否包含 deepseek provider 块
file_has_deepseek_blocks() {
    local f="$1"
    [ -f "$f" ] && grep -q "\[model_providers\.${DEEPSEEK_PROVIDER_NAME}\]" "$f" 2>/dev/null
}

# 确保 deepseek provider 块存在于指定文件中（幂等）
ensure_deepseek_blocks() {
    local target_file="$1"
    if file_has_deepseek_blocks "$target_file"; then
        return 0
    fi
    print_info "向 ${target_file} 追加 DeepSeek provider 配置块..."
    {
        generate_deepseek_provider_toml
        generate_deepseek_properties_toml
    } >> "$target_file"
}

# 基于 config_openai.toml 构建 config_deepseek.toml
build_config_deepseek() {
    local openai_cfg deepseek_cfg
    openai_cfg="$(config_openai_toml)"
    deepseek_cfg="$(config_deepseek_toml)"

    # 需要源文件
    if [ ! -f "$openai_cfg" ]; then
        print_error "OpenAI 配置文件不存在: ${openai_cfg}"
        print_info "请先运行 Codex 一次生成初始配置，或手动创建该文件"
        return 1
    fi

    print_info "基于 config_openai.toml 构建 config_deepseek.toml..."

    # 复制 openai 配置为基础
    cp "$openai_cfg" "$deepseek_cfg"

    # 设置/替换 model_provider
    if grep -q '^model_provider\s*=' "$deepseek_cfg" 2>/dev/null; then
        sed -i "s/^model_provider\s*=.*/model_provider = \"${DEEPSEEK_PROVIDER_NAME}\"/" "$deepseek_cfg"
    else
        sed -i "1i model_provider = \"${DEEPSEEK_PROVIDER_NAME}\"" "$deepseek_cfg"
    fi

    # 设置/替换 model（DeepSeek 模型名；gpt-5.x 等 OpenAI 模型名在 deepseek provider 下无效）
    if grep -q '^model\s*=' "$deepseek_cfg" 2>/dev/null; then
        sed -i "s/^model\s*=.*/model = \"${DEEPSEEK_MODEL_NAME}\"/" "$deepseek_cfg"
    else
        sed -i "1i model = \"${DEEPSEEK_MODEL_NAME}\"" "$deepseek_cfg"
    fi

    # 追加 deepseek provider 和模型属性块
    ensure_deepseek_blocks "$deepseek_cfg"

    print_info "config_deepseek.toml 已生成"
}

# 切换到 DeepSeek（使用相对路径软连接，跨容器/宿主机兼容）
switch_to_deepseek() {
    local cfg deepseek_cfg
    cfg="$(codex_config_toml)"
    deepseek_cfg="$(config_deepseek_toml)"

    # 确保 deepseek 配置文件存在
    if [ ! -f "$deepseek_cfg" ]; then
        build_config_deepseek || return 1
    else
        # 配置文件已存在，但确保 provider 块是最新的（Moon Bridge 地址可能变了）
        ensure_deepseek_blocks "$deepseek_cfg"
        # 同步 model_provider 和 model 字段
        if grep -q '^model_provider\s*=' "$deepseek_cfg" 2>/dev/null; then
            sed -i "s/^model_provider\s*=.*/model_provider = \"${DEEPSEEK_PROVIDER_NAME}\"/" "$deepseek_cfg"
        fi
        if grep -q '^model\s*=' "$deepseek_cfg" 2>/dev/null; then
            sed -i "s/^model\s*=.*/model = \"${DEEPSEEK_MODEL_NAME}\"/" "$deepseek_cfg"
        fi
    fi

    # 切换到 config_deepseek.toml（使用相对路径，容器 mount 后也能正确解析）
    cd "$(codex_home)"
    rm -f "$cfg"
    ln -sf "$(basename "$deepseek_cfg")" "$cfg"
    print_info "已切换: config.toml -> $(basename "$deepseek_cfg")"
    cd - >/dev/null
}

# 切换到 OpenAI（使用相对路径软连接）
switch_to_openai() {
    local cfg openai_cfg
    cfg="$(codex_config_toml)"
    openai_cfg="$(config_openai_toml)"

    if [ ! -f "$openai_cfg" ]; then
        print_error "OpenAI 配置文件不存在: ${openai_cfg}"
        print_info "请检查是否已完成首次迁移"
        return 1
    fi

    cd "$(codex_home)"
    rm -f "$cfg"
    ln -sf "$(basename "$openai_cfg")" "$cfg"
    print_info "已切换: config.toml -> $(basename "$openai_cfg")"
    cd - >/dev/null
}

# 获取当前活跃的 provider（通过检查软连接目标）
get_active_provider_name() {
    local cfg
    cfg="$(codex_config_toml)"
    if [ -L "$cfg" ]; then
        local target
        target=$(readlink "$cfg" 2>/dev/null || true)
        case "$target" in
            *config_deepseek*) printf 'deepseek' ;;
            *config_openai*)   printf 'openai' ;;
            *)                 printf 'unknown' ;;
        esac
    elif [ -f "$cfg" ]; then
        # 尚未迁移，从文件内容读取
        grep -oP '^model_provider\s*=\s*"\K[^"]+' "$cfg" 2>/dev/null | head -1 || printf 'openai'
    else
        printf 'none'
    fi
}

# 生成 models_catalog.json（Codex 模型目录）
generate_models_catalog() {
    local catalog_file
    catalog_file="$(codex_models_catalog)"

    mkdir -p "$(codex_home)"

    cat > "$catalog_file" <<CATALOG_EOF
{
  "models": [
    {
      "id": "${DEEPSEEK_MODEL_NAME}",
      "name": "DeepSeek V4 Pro",
      "provider": "${DEEPSEEK_PROVIDER_NAME}",
      "context_window": 262144,
      "max_context_window": 1048576,
      "max_output_tokens": 384000,
      "supports_parallel_tool_calls": true,
      "supports_reasoning_summaries": true,
      "supports_tool_calls": true,
      "input_modalities": ["text"],
      "pricing": {
        "input_per_1m_tokens": 2.0,
        "output_per_1m_tokens": 8.0,
        "cache_write_per_1m_tokens": 1.0,
        "cache_read_per_1m_tokens": 0.2
      },
      "description": "DeepSeek V4 Pro — 通过 Moon Bridge 本地转发接入 Codex"
    }
  ],
  "_note": "此文件由 setup_codex_deepseek.sh 自动生成。如需添加更多模型，请编辑此文件。"
}
CATALOG_EOF
    print_info "模型目录已生成: ${catalog_file}"
}

# ======================== 高级操作 ========================
# 启用 DeepSeek：迁移配置 → 构建 deepseek 配置 → 启动 Moon Bridge → 切换软连接
enable_deepseek() {
    echo ""
    echo "========================================="
    echo "   启用 DeepSeek 作为 Codex 模型后端"
    echo "========================================="
    echo ""

    # 1. 确保 Moon Bridge 可用
    print_step "1/5 准备 Moon Bridge..."
    ensure_moonbridge_binary || return 1
    generate_moonbridge_config || return 1

    # 2. 启动 Moon Bridge
    print_step "2/5 启动 Moon Bridge 服务..."
    start_moonbridge || return 1

    # 3. 迁移为双文件+软连接方案（首次）或确保结构正确
    print_step "3/5 准备配置结构..."
    migrate_to_symlink
    build_config_deepseek

    # 4. 生成模型目录
    print_step "4/5 生成模型目录..."
    generate_models_catalog

    # 5. 切换软连接到 deepseek 配置
    print_step "5/5 切换模型..."
    switch_to_deepseek

    echo ""
    print_info "========================================="
    print_info "  DeepSeek 已启用！"
    print_info "========================================="
    print_info ""
    print_info "配置文件:"
    print_info "  config.toml          -> config_deepseek.toml  (软连接)"
    print_info "  config_openai.toml   — 原 OpenAI 配置（未修改）"
    print_info "  config_deepseek.toml — DeepSeek 配置"
    print_info ""
    print_info "当前配置:"
    print_info "  Codex 目录:   $(codex_home)"
    local mb_url
    mb_url="$(moonbridge_base_url)"
    print_info "  Moon Bridge:  ${mb_url}"
    print_info "  活跃模型:     ${DEEPSEEK_MODEL_NAME}"
    print_info "  提供商:       ${DEEPSEEK_PROVIDER_NAME}"
    print_info ""
    print_info "验证:"
    print_info "  curl $(moonbridge_base_url | sed 's|/v1$||')/v1/models"
    print_info ""
    print_info "切换回 OpenAI:"
    print_info "  bash setup_codex_deepseek.sh --use-openai"
    echo ""
}

# 切换回 OpenAI（改软连接指向 config_openai.toml）
enable_openai() {
    echo ""
    echo "========================================="
    echo "   切换 Codex 回 OpenAI 模型后端"
    echo "========================================="
    echo ""

    local cfg
    cfg="$(codex_config_toml)"

    # 首次迁移
    migrate_to_symlink

    # 切换软连接
    switch_to_openai

    # 询问是否停止 Moon Bridge
    if is_moonbridge_running; then
        echo ""
        local port
        port="$(moonbridge_port)"
        print_info "Moon Bridge 仍在运行。是否停止？（停止后可释放端口 ${port}）"
        read -r -p "停止 Moon Bridge? [Y/n]: " stop_confirm
        if [ "$stop_confirm" != "n" ] && [ "$stop_confirm" != "N" ]; then
            stop_moonbridge
        else
            print_info "Moon Bridge 保持运行（如需停止，执行: bash setup_codex_deepseek.sh --stop-moonbridge）"
        fi
    fi

    echo ""
    print_info "Codex 已切换回 OpenAI 模型"
    print_info "config.toml -> config_openai.toml"
    print_info "原 OpenAI 配置完整保留，包括 model、project trusts 等所有字段"
}

# ======================== 状态检查 ========================
show_status() {
    echo ""
    echo "========================================="
    echo "   Codex + DeepSeek 状态检查"
    echo "========================================="
    echo ""

    # Codex 信息
    echo "--- Codex ---"
    echo "  CODEX_HOME:        $(codex_home)"
    if check_command codex; then
        echo "  Codex CLI:         $(codex --version 2>/dev/null || echo '已安装')"
    else
        echo "  Codex CLI:         未安装"
    fi

    local config_file active_provider
    config_file="$(codex_config_toml)"
    if [ -f "$config_file" ]; then
        active_provider=$(get_active_provider_name)
        echo "  config.toml:       ${config_file}"
        if [ -L "$config_file" ]; then
            echo "  软连接指向:        $(readlink "$config_file")"
        fi
        echo "  活跃 provider:     ${active_provider:-未设置}"
        if [ -f "$(config_deepseek_toml)" ]; then
            echo "  DeepSeek 配置:     $(config_deepseek_toml) ✓"
        else
            echo "  DeepSeek 配置:     未创建 ✗"
        fi
        if [ -f "$(config_openai_toml)" ]; then
            echo "  OpenAI 配置:       $(config_openai_toml) ✓"
        else
            echo "  OpenAI 配置:       未创建 ✗"
        fi
    else
        echo "  config.toml:       不存在"
    fi

    if [ -f "$(codex_models_catalog)" ]; then
        echo "  models_catalog:    存在 ✓"
    else
        echo "  models_catalog:    不存在 ✗"
    fi

    echo ""

    # Moon Bridge 信息
    echo "--- Moon Bridge ---"
    local bin_path
    bin_path="$(moonbridge_bin)"
    if [ -x "$bin_path" ]; then
        echo "  二进制:            ${bin_path} ✓"
    else
        echo "  二进制:            不存在 ✗"
    fi

    if [ -f "$(moonbridge_config)" ]; then
        echo "  配置文件:          $(moonbridge_config) ✓"
    else
        echo "  配置文件:          不存在 ✗"
    fi

    if is_moonbridge_running; then
        echo "  运行状态:          运行中 ✓（PID: $(get_moonbridge_pid)，端口: $(moonbridge_port)）"
        echo "  监听地址:          $(moonbridge_base_url)"
    else
        echo "  运行状态:          未运行 ✗"
    fi

    if [ -f "$(moonbridge_log)" ]; then
        echo "  日志文件:          $(moonbridge_log)"
    fi

    echo ""

    # 连通性测试
    if is_moonbridge_running; then
        echo "--- 连通性测试 ---"
        if check_command curl; then
            local models_response
            models_response=$(curl -s -o /dev/null -w "%{http_code}" "$(moonbridge_base_url | sed 's|/v1$||')/v1/models" 2>/dev/null || echo "000")
            if [ "$models_response" = "200" ]; then
                print_info "/v1/models 端点可达（HTTP ${models_response}）"
            else
                print_warn "/v1/models 端点异常（HTTP ${models_response}）"
            fi
        else
            print_warn "curl 不可用，跳过连通性测试"
        fi
    fi

    echo ""
}

# ======================== 使用说明 ========================
usage() {
    cat <<'EOF'
用法: bash setup_codex_deepseek.sh [选项]

将 DeepSeek 作为 Codex 的模型选项之一，通过 Moon Bridge 本地转发层接入。

═══════════════════════════════════════════════════════════
  核心操作
═══════════════════════════════════════════════════════════
  --use-deepseek         启用 DeepSeek（启动 Moon Bridge + 配置 Codex）
  --use-openai           切换回 OpenAI 默认后端
  --status               查看当前状态

═══════════════════════════════════════════════════════════
  Moon Bridge 管理
═══════════════════════════════════════════════════════════
  --setup-moonbridge     仅准备 Moon Bridge（克隆/构建 + 生成配置）
  --start-moonbridge     仅启动 Moon Bridge
  --stop-moonbridge      仅停止 Moon Bridge
  --moonbridge-addr URL  指定 Moon Bridge 地址
                          默认: 自动探测可用端口 (范围 ${MOON_BRIDGE_PORT_MIN}-${MOON_BRIDGE_PORT_MAX})
                          用于指向宿主机或其他机器上已有的 Moon Bridge 实例
  --moonbridge-bin PATH  指定 Moon Bridge 二进制路径
                          可跳过构建步骤，直接使用已有二进制

═══════════════════════════════════════════════════════════
  API Key
═══════════════════════════════════════════════════════════
  --api-key KEY          直接提供 DeepSeek API Key（不交互式输入）
  --api-key-file PATH    从文件读取 DeepSeek API Key

═══════════════════════════════════════════════════════════
  其他
═══════════════════════════════════════════════════════════
  --force-reconfigure    强制重新生成 Moon Bridge 配置（覆盖已有配置）
  -h, --help             显示此帮助信息

═══════════════════════════════════════════════════════════
  环境变量
═══════════════════════════════════════════════════════════
  CODEX_HOME             Codex 配置目录（默认: ~/.codex）
  DEEPSEEK_API_KEY       DeepSeek API Key（避免交互输入）
  DEEPSEEK_API_KEY_FILE  DeepSeek API Key 文件路径

═══════════════════════════════════════════════════════════
  多容器 / 宿主机场景
═══════════════════════════════════════════════════════════
  由于容器使用 --network=host，与宿主机共享网络命名空间，
  Moon Bridge 只需在宿主机运行一次，所有容器均可访问。

  推荐流程：
    1) 宿主机: bash setup_codex_deepseek.sh --use-deepseek
    2) 容器内: bash setup_codex_deepseek.sh --use-deepseek \
                 --moonbridge-addr http://127.0.0.1:38440/v1
       （容器会复用宿主机的 Moon Bridge，仅配置 Codex 侧）

  或直接在宿主机完成所有配置，容器通过 volume 挂载 ~/.codex 目录共享配置。

═══════════════════════════════════════════════════════════
  示例
═══════════════════════════════════════════════════════════
  # 一键启用 DeepSeek
  bash setup_codex_deepseek.sh --use-deepseek

  # 仅从宿主机启动 Moon Bridge（容器将复用）
  bash setup_codex_deepseek.sh --start-moonbridge

  # 检查状态
  bash setup_codex_deepseek.sh --status

  # 切换回 OpenAI
  bash setup_codex_deepseek.sh --use-openai

  # 容器中配置（复用宿主机 Moon Bridge）
  bash setup_codex_deepseek.sh --use-deepseek \
    --moonbridge-addr http://127.0.0.1:38440/v1

  参考文档: https://cloud.tencent.com/developer/article/2671457
EOF
}

# ======================== 主入口 ========================
main() {
    local action=""
    local setup_moonbridge_only=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --use-deepseek)
                action="enable_deepseek"
                ;;
            --use-openai)
                action="enable_openai"
                ;;
            --status)
                action="show_status"
                ;;
            --setup-moonbridge)
                setup_moonbridge_only=1
                ;;
            --start-moonbridge)
                action="start_moonbridge"
                ;;
            --stop-moonbridge)
                action="stop_moonbridge"
                ;;
            --moonbridge-addr)
                shift
                MOONBRIDGE_ADDR="$1"
                ;;
            --moonbridge-bin)
                shift
                MOONBRIDGE_BIN_OVERRIDE="$1"
                ;;
            --api-key)
                shift
                DEEPSEEK_API_KEY="$1"
                ;;
            --api-key-file)
                shift
                DEEPSEEK_API_KEY_FILE="$1"
                ;;
            --force-reconfigure)
                FORCE_RECONFIGURE=1
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                print_error "未知参数: $1"
                usage
                return 1
                ;;
        esac
        shift
    done

    # --setup-moonbridge 只准备 Moon Bridge，不操作 Codex 配置
    if [ "$setup_moonbridge_only" -eq 1 ]; then
        print_step "准备 Moon Bridge..."
        ensure_moonbridge_binary || return 1
        generate_moonbridge_config || return 1
        print_info "Moon Bridge 准备完毕。启动: bash setup_codex_deepseek.sh --start-moonbridge"
        return 0
    fi

    # 执行对应操作
    case "$action" in
        enable_deepseek)
            enable_deepseek
            ;;
        enable_openai)
            enable_openai
            ;;
        show_status)
            show_status
            ;;
        start_moonbridge)
            ensure_moonbridge_binary || return 1
            generate_moonbridge_config || return 1
            start_moonbridge
            ;;
        stop_moonbridge)
            stop_moonbridge
            ;;
        *)
            # 默认显示状态
            show_status
            echo ""
            print_info "请指定操作。常用: --use-deepseek | --use-openai | --status"
            echo ""
            ;;
    esac
}

main "$@"
