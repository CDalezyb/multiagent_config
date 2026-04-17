#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

install_opencode() {
    print_info "Installing OpenCode..."
    
    if check_command opencode; then
        print_warn "OpenCode already installed: $(opencode --version)"
        return 0
    fi
    
    curl -fsSL https://opencode.ai/install | bash
    
    export PATH="$HOME/.opencode/bin:$PATH"
    
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q '.opencode/bin' "$HOME/.bashrc"; then
            echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
        fi
    fi
    
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -q '.opencode/bin' "$HOME/.zshrc"; then
            echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$HOME/.zshrc"
        fi
    fi
    
    print_info "OpenCode installed successfully"
}

setup_global_rules() {
    print_info "Setting up global rules..."
    
    mkdir -p "$HOME/.config/opencode"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    RULES_FILE="$SCRIPT_DIR/GLOBAL_RULES.md"
    
    if [ -f "$RULES_FILE" ]; then
        cp "$RULES_FILE" "$HOME/.config/opencode/AGENTS.md"
        print_info "Global rules copied to ~/.config/opencode/AGENTS.md"
    else
        print_error "GLOBAL_RULES.md not found at $RULES_FILE"
        return 1
    fi
}

setup_openai_config() {
    print_info "Configuring OpenAI API..."
    
    if [ -z "$OPENAI_API_KEY" ]; then
        print_warn "OPENAI_API_KEY environment variable is not set"
        echo ""
        echo "How to get OpenAI API Key:"
        echo "1. Go to https://platform.openai.com/"
        echo "2. Log in to your account"
        echo "3. Navigate to API Keys: https://platform.openai.com/api-keys"
        echo "4. Click 'Create new secret key'"
        echo "5. Copy the key and set it:"
        echo "   export OPENAI_API_KEY='sk-your-key-here'"
        echo ""
        read -p "Enter your OpenAI API Key (or press Enter to skip): " api_key
        
        if [ -n "$api_key" ]; then
            export OPENAI_API_KEY="$api_key"
        else
            print_warn "Skipping API key configuration"
            return 0
        fi
    else
        print_info "OPENAI_API_KEY is already set"
    fi
    
    mkdir -p "$HOME/.config/opencode"
    
    if [ -f "$HOME/.config/opencode/opencode.json" ]; then
        print_info "Updating existing opencode.json"
    else
        cat > "$HOME/.config/opencode/opencode.json" << 'EOF'
{
  "$schema": "https://opencode.ai/config.json"
}
EOF
    fi
    
    print_info "API key configured (using environment variable OPENAI_API_KEY)"
    
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q 'OPENAI_API_KEY' "$HOME/.bashrc"; then
            echo "export OPENAI_API_KEY='$OPENAI_API_KEY'" >> "$HOME/.bashrc"
        fi
    fi
    
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -q 'OPENAI_API_KEY' "$HOME/.zshrc"; then
            echo "export OPENAI_API_KEY='$OPENAI_API_KEY'" >> "$HOME/.zshrc"
        fi
    fi
    
    print_info "OpenAI API configuration complete"
}

main() {
    echo "========================================="
    echo "  OpenCode Container Setup Script"
    echo "========================================="
    echo ""
    
    install_opencode
    echo ""
    setup_global_rules
    echo ""
    setup_openai_config
    echo ""
    
    print_info "Setup complete!"
    echo ""
    echo "To start OpenCode, run:"
    echo "  source ~/.bashrc  # or ~/.zshrc"
    echo "  opencode"
    echo ""
    echo "Or with API key:"
    echo "  OPENAI_API_KEY=sk-... opencode"
}

main "$@"
