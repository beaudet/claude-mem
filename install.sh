#!/bin/bash
set -e

# Claude-mem installer for Linux
# Usage: ./install.sh
# Idempotent - safe to run multiple times

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGINS_DIR="$HOME/.claude/plugins"
MARKETPLACE_DIR="$CLAUDE_PLUGINS_DIR/marketplaces/thedotmack"
CLAUDE_MEM_DIR="$HOME/.claude-mem"

log() { echo -e "\033[1;34m==>\033[0m $1"; }
ok() { echo -e "\033[1;32m✓\033[0m $1"; }
warn() { echo -e "\033[1;33m!\033[0m $1"; }
err() { echo -e "\033[1;31m✗\033[0m $1" >&2; }

# Check for required commands
check_cmd() {
    command -v "$1" &>/dev/null
}

# Install bun if missing
install_bun() {
    if check_cmd bun; then
        ok "bun already installed: $(bun --version)"
        return 0
    fi
    log "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
    ok "bun installed: $(bun --version)"
}

# Install uv/uvx if missing
install_uv() {
    if check_cmd uvx; then
        ok "uvx already installed: $(uv --version)"
        return 0
    fi
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    ok "uv installed: $(uv --version)"
}

# Ensure PATH is configured for future sessions
setup_path() {
    local path_line='export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"'
    local updated=0

    for profile in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
        if [ -f "$profile" ]; then
            if ! grep -q '.bun/bin' "$profile" 2>/dev/null; then
                echo "$path_line" >> "$profile"
                updated=1
            fi
        fi
    done

    [ $updated -eq 1 ] && ok "PATH added to shell profiles" || ok "PATH already configured"
}

# Create required directories
create_dirs() {
    log "Creating directories..."
    mkdir -p "$CLAUDE_PLUGINS_DIR/cache/thedotmack/claude-mem"
    mkdir -p "$MARKETPLACE_DIR"
    mkdir -p "$CLAUDE_MEM_DIR/logs"
    mkdir -p "$CLAUDE_MEM_DIR/vector-db"
    ok "Directories created"
}

# Register marketplace in Claude
register_marketplace() {
    local known_file="$CLAUDE_PLUGINS_DIR/known_marketplaces.json"

    if [ ! -f "$known_file" ]; then
        echo '{}' > "$known_file"
    fi

    if grep -q '"thedotmack"' "$known_file" 2>/dev/null; then
        ok "Marketplace already registered"
        return 0
    fi

    log "Registering marketplace..."
    local tmp=$(mktemp)
    if check_cmd python3; then
        python3 -c "
import json
with open('$known_file', 'r') as f:
    data = json.load(f)
data['thedotmack'] = {
    'source': {'source': 'directory', 'path': '$MARKETPLACE_DIR'},
    'installLocation': '$MARKETPLACE_DIR',
    'lastUpdated': '$(date -Iseconds)'
}
with open('$tmp', 'w') as f:
    json.dump(data, f, indent=2)
"
        mv "$tmp" "$known_file"
        ok "Marketplace registered"
    else
        warn "python3 not found - manually add thedotmack to $known_file"
    fi
}

# Install npm dependencies
install_deps() {
    log "Installing dependencies..."
    cd "$SCRIPT_DIR"
    npm install --silent
    ok "Dependencies installed"
}

# Build and sync plugin
build_plugin() {
    log "Building plugin..."
    cd "$SCRIPT_DIR"
    npm run build --silent
    ok "Plugin built"

    log "Syncing to marketplace..."
    local version=$(node -p "require('./plugin/.claude-plugin/plugin.json').version")
    local cache_dir="$CLAUDE_PLUGINS_DIR/cache/thedotmack/claude-mem/$version"
    mkdir -p "$cache_dir"

    rsync -a --delete --exclude=.git ./ "$MARKETPLACE_DIR/"
    rsync -a --delete --exclude=.git plugin/ "$cache_dir/"

    # Copy marketplace.json to root if needed
    [ -f "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" ] && \
        cp "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" "$MARKETPLACE_DIR/marketplace.json" 2>/dev/null || true

    cd "$MARKETPLACE_DIR" && npm install --silent
    ok "Plugin synced (v$version)"
}

# Pre-warm Chroma to download models
prewarm_chroma() {
    log "Pre-warming Chroma (downloading embedding models)..."
    timeout 30 uvx --python 3.13 chroma-mcp --client-type persistent --data-dir "$CLAUDE_MEM_DIR/vector-db" &>/dev/null &
    local pid=$!
    sleep 10
    kill $pid 2>/dev/null || true
    ok "Chroma models cached"
}

# Start worker
start_worker() {
    log "Starting worker..."
    bun "$MARKETPLACE_DIR/plugin/scripts/worker-service.cjs" start &>/dev/null &
    sleep 3

    if curl -s http://127.0.0.1:37777/api/health | grep -q '"status":"ok"'; then
        ok "Worker running on port 37777"
    else
        warn "Worker may not have started - check logs at $CLAUDE_MEM_DIR/logs/"
    fi
}

# Verify installation
verify() {
    log "Verifying installation..."
    local errors=0

    check_cmd bun || { err "bun not in PATH"; errors=$((errors+1)); }
    check_cmd uvx || { err "uvx not in PATH"; errors=$((errors+1)); }
    [ -d "$MARKETPLACE_DIR/plugin" ] || { err "Plugin not synced"; errors=$((errors+1)); }
    [ -f "$CLAUDE_MEM_DIR/claude-mem.db" ] || warn "Database not yet created (will be on first use)"

    if [ $errors -eq 0 ]; then
        ok "Installation verified"
        return 0
    else
        err "$errors errors found"
        return 1
    fi
}

main() {
    echo ""
    echo "Claude-mem Installer"
    echo "===================="
    echo ""

    install_bun
    install_uv
    setup_path
    create_dirs
    register_marketplace
    install_deps
    build_plugin
    prewarm_chroma
    start_worker
    verify

    echo ""
    echo "Installation complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Restart your terminal (or: source ~/.bashrc)"
    echo "  2. Run: claude /plugin install thedotmack/claude-mem"
    echo "  3. Restart Claude Code"
    echo ""
    echo "Web viewer: http://localhost:37777"
    echo ""
}

main "$@"
