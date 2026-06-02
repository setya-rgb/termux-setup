#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.2.0"

# ----------------------------------------------------------------------
# Usage / Help
# ----------------------------------------------------------------------
usage() {
    cat <<EOF
termux [-hV]

Options:
  -h|--help      Print this help dialogue and exit
  -V|--version   Print the current version and exit

Environment variables:
  TERMUX_SPINNER_STYLE    Spinner style (0-5)        (default: 0)
  TERMUX_SPINNER_VERBOSE  Show command output on success (set to any value)
EOF
}

# ----------------------------------------------------------------------
# Configuration & Constants
# ----------------------------------------------------------------------
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'

readonly CORE_PACKAGES=(git zsh neovim)
readonly MODERN_TOOLS=(eza zoxide fzf bat ripgrep)
readonly EXTRA_TOOLS=(duf bottom tlrc fd)   # duf, bottom, tldr, fd
readonly LAZYGIT_REPO="https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_0.40.2_Linux_arm64.tar.gz"

# ----------------------------------------------------------------------
# Helper Functions (coloured output)
# ----------------------------------------------------------------------
print_msg() {
    local color="$1"; shift
    echo -e "${color}$*${COLOR_RESET}"
}

status() { print_msg "$COLOR_BLUE" "==> $*"; }
success() { print_msg "$COLOR_GREEN" "✓ $*"; }
warn()    { print_msg "$COLOR_YELLOW" "⚠ $*"; }
error()   { print_msg "$COLOR_RED" "✗ $*"; }

# ----------------------------------------------------------------------
# Advanced Spinner with Time & Styles
# ----------------------------------------------------------------------
readonly SPINNER_STYLES=(
    "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"                    # braille dots
    "◐◓◑◒"                                   # classic
    "▁▂▃▄▅▆▇█▇▆▅▄▃▂▁"                       # breathing bar
    "⣾⣽⣻⢿⡿⣟⣯⣷"                       # bold braille
    "←↖↑↗→↘↓↙"                               # arrows
    "●◔◐◕○"                                  # fading circle
)

_get_spinner_chars() {
    local style_idx=${TERMUX_SPINNER_STYLE:-0}
    if [[ $style_idx -ge ${#SPINNER_STYLES[@]} ]]; then
        style_idx=0
    fi
    echo -n "${SPINNER_STYLES[$style_idx]}"
}

_spinner_pid=""
_spinner_active=false
_spinner_start_time=0

_cleanup_spinner() {
    if [[ "$_spinner_active" == true ]] && [[ -n "$_spinner_pid" ]] && kill -0 "$_spinner_pid" 2>/dev/null; then
        kill "$_spinner_pid" 2>/dev/null || true
        wait "$_spinner_pid" 2>/dev/null || true
    fi
    _spinner_active=false
    tput cnorm 2>/dev/null || true
    printf "\r%*s\r" "$(tput cols 2>/dev/null || echo 80)" ""
}

_format_elapsed() {
    local elapsed=$1
    if (( $(echo "$elapsed < 60" | bc -l 2>/dev/null || echo 0) )); then
        printf "%.1fs" "$elapsed"
    elif (( $(echo "$elapsed < 3600" | bc -l 2>/dev/null || echo 0) )); then
        printf "%dm %ds" $((elapsed/60)) $((elapsed%60))
    else
        printf "%dh %dm" $((elapsed/3600)) $((elapsed%3600/60))
    fi
}

_run_spinner() {
    local msg="$1"
    local spinchars
    spinchars="$(_get_spinner_chars)"
    local len=${#spinchars}
    local i=0
    local start_time=${_spinner_start_time:-$(date +%s.%N)}
    tput civis 2>/dev/null || true

    while true; do
        local now
        now=$(date +%s.%N)
        local elapsed
        elapsed=$(echo "$now - $start_time" | bc 2>/dev/null || echo "0")
        local elapsed_str
        elapsed_str="$(_format_elapsed "$elapsed")"
        printf "\r%s [%c] %s" "$msg" "${spinchars:i++%len:1}" "$elapsed_str"
        sleep 0.08
    done
}

run_with_spinner() {
    local msg="$1"
    shift
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"

    _spinner_start_time=$(date +%s.%N)

    "$@" >"$stdout_file" 2>"$stderr_file" &
    local cmd_pid=$!

    _run_spinner "$msg" &
    _spinner_pid=$!
    _spinner_active=true

    local exit_code=0
    wait "$cmd_pid" || exit_code=$?

    _cleanup_spinner

    if [[ $exit_code -eq 0 ]]; then
        success "$msg done"
        if [[ -n "${TERMUX_SPINNER_VERBOSE:-}" ]] && [[ -s "$stdout_file" ]]; then
            echo "Output:"
            cat "$stdout_file"
        fi
        rm -f "$stdout_file" "$stderr_file"
        return 0
    else
        error "$msg failed (exit code: $exit_code)"
        if [[ -s "$stderr_file" ]]; then
            echo "Error (first 5 lines):"
            head -n 5 "$stderr_file" >&2
        fi
        if [[ -n "${TERMUX_SPINNER_VERBOSE:-}" ]] && [[ -s "$stdout_file" ]]; then
            echo "Standard output:"
            cat "$stdout_file"
        fi
        rm -f "$stdout_file" "$stderr_file"
        return $exit_code
    fi
}

trap _cleanup_spinner EXIT INT TERM

# ----------------------------------------------------------------------
# Installation Helpers
# ----------------------------------------------------------------------
install_if_missing() {
    local pkg="$1"
    if pkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        warn "$pkg already installed, skipping"
        return 0
    fi
    run_with_spinner "Installing $pkg" pkg install -y "$pkg"
}

check_termux() {
    if [[ ! -d "/data/data/com.termux" ]] && [[ ! -f "/data/data/com.termux/files/usr/bin/termux-setup-storage" ]]; then
        error "This script is designed for Termux only. Exiting."
        exit 1
    fi
    status "Termux environment detected."
}

setup_termux_properties() {
    local termux_dir="$HOME/.termux"
    local prop_file="$termux_dir/termux.properties"
    local backup_dir="$termux_dir/backups"

    status "Configuring Termux properties..."
    mkdir -p "$termux_dir"

    if [[ -f "$prop_file" ]]; then
        mkdir -p "$backup_dir"
        local backup_name="termux.properties.$(date +%Y%m%d_%H%M%S)"
        cp "$prop_file" "$backup_dir/$backup_name"
        warn "Existing $prop_file backed up to $backup_dir/$backup_name"
    fi

    cat > "$prop_file" <<'EOF'
# Disable audible bell
bell-character = ignore

# Extra keys row (Ctrl, Alt, Esc, etc.)
extra-keys = [['ESC','/','-','HOME','UP','END','PGUP'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]

# Back button hides keyboard
back-button = hide-keyboard

# Volume down toggles extra keys
volume-down-toggle = true

# Volume keys move cursor
volume-keys = cursor

# Cursor blink rate (ms)
terminal-cursor-blink-rate = 1400

# Cursor style: bar
terminal-cursor-style = bar
EOF

    success "Termux properties updated (restart Termux to apply)"
}

install_lazygit() {
    if command -v lazygit >/dev/null 2>&1; then
        warn "lazygit already installed, skipping"
        return 0
    fi

    status "Installing lazygit from GitHub releases..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    cd "$tmp_dir"

    if curl -fsSL "$LAZYGIT_REPO" -o lazygit.tar.gz; then
        tar -xzf lazygit.tar.gz
        chmod +x lazygit
        mv lazygit "$PREFIX/bin/lazygit"
        success "lazygit installed"
    else
        warn "Failed to download lazygit – skipping"
    fi
    cd - >/dev/null
    rm -rf "$tmp_dir"
}

setup_zsh() {
    local antigen_dir="$HOME/.local/share/zsh"
    local antigen_file="$antigen_dir/antigen.zsh"
    local zshrc="$HOME/.zshrc"
    local zshrc_backup="$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"

    status "Configuring Zsh environment..."

    if [[ -f "$zshrc" ]]; then
        cp "$zshrc" "$zshrc_backup"
        warn "Existing .zshrc backed up to $zshrc_backup"
    fi

    mkdir -p "$antigen_dir"
    if [[ ! -f "$antigen_file" ]]; then
        run_with_spinner "Downloading Antigen" curl -fsSL git.io/antigen -o "$antigen_file"
    else
        warn "Antigen already present, skipping download"
    fi

    cat > "$zshrc" <<'EOF'
# Load Antigen
source ~/.local/share/zsh/antigen.zsh

# Use Oh My Zsh as bundle base
antigen use oh-my-zsh

# Bundles
antigen bundle git
antigen bundle command-not-found

# Additional plugins
antigen bundle zsh-users/zsh-completions
antigen bundle zsh-users/zsh-autosuggestions
antigen bundle zsh-users/zsh-syntax-highlighting

# Powerlevel10k theme
antigen bundle romkatv/powerlevel10k

antigen apply

# ----------------------------------------------------------------------
# eza (modern ls)
# ----------------------------------------------------------------------
if command -v eza >/dev/null 2>&1; then
    alias ls='eza'
    alias la='eza -la'
    alias ll='eza -l'
    alias l='eza -1'
    alias tree='eza --tree'
    alias l.='eza -a | grep -E "^\."'
fi

# ----------------------------------------------------------------------
# zoxide (smart cd)
# ----------------------------------------------------------------------
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
    alias cd='z'
fi

# ----------------------------------------------------------------------
# Other modern aliases
# ----------------------------------------------------------------------
if command -v bat >/dev/null 2>&1; then
    alias cat='bat --paging=never'
    alias less='bat'
fi

if command -v fzf >/dev/null 2>&1; then
    source <(fzf --zsh 2>/dev/null || true)
fi

if command -v duf >/dev/null 2>&1; then
    alias df='duf'
fi

if command -v bottom >/dev/null 2>&1; then
    alias htop='bottom'
fi

if command -v fd >/dev/null 2>&1; then
    alias find='fd'
fi

# ----------------------------------------------------------------------
# Common aliases
# ----------------------------------------------------------------------
alias gs='git status'
alias gl='git log --oneline --graph'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='rg'

# ----------------------------------------------------------------------
# Key bindings
# ----------------------------------------------------------------------
bindkey '^r' fzf-history-widget
EOF

    success ".zshrc created"
}

setup_nvchad() {
    local nvim_config="$HOME/.config/nvim"

    status "Setting up NvChad..."

    if [[ -d "$nvim_config" ]]; then
        warn "NvChad already exists at $nvim_config, skipping installation"
        return 0
    fi

    if ! command -v nvim >/dev/null 2>&1; then
        run_with_spinner "Installing Neovim" pkg install -y neovim
    fi

    run_with_spinner "Cloning NvChad" git clone --depth 1 https://github.com/NvChad/NvChad "$nvim_config"

    status "Installing Neovim plugins (headless)..."
    nvim --headless -c 'autocmd User PackerComplete quitall' -c 'PackerSync' 2>/dev/null || {
        warn "Headless sync failed – run 'nvim' and type ':PackerSync' manually"
    }

    success "NvChad setup complete"
}

setup_font() {
    local termux_dir="$HOME/.termux"
    local font_target="$termux_dir/font.otf"
    local font_url="https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf"

    status "Downloading Powerlevel10k font..."
    if [[ -f "$font_target" ]]; then
        warn "Font already exists at $font_target, skipping download"
        return 0
    fi

    mkdir -p "$termux_dir"
    run_with_spinner "Downloading font" curl -fsSL -o "$font_target" "$font_url"
    success "Font downloaded to $font_target"
}

# ----------------------------------------------------------------------
# Main Setup Routine
# ----------------------------------------------------------------------
main() {
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        clear
    fi

    print_msg "$COLOR_CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_msg "$COLOR_CYAN" "          Termux Setup Script v$VERSION    "
    print_msg "$COLOR_CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    check_termux

    run_with_spinner "Updating package lists" pkg update -y
    run_with_spinner "Upgrading packages" pkg upgrade -y

    touch "$HOME/.hushlogin"

    status "Setting up storage access..."
    termux-setup-storage || warn "Storage setup might be incomplete"

    for pkg in "${CORE_PACKAGES[@]}"; do
        install_if_missing "$pkg"
    done

    for pkg in "${MODERN_TOOLS[@]}"; do
        install_if_missing "$pkg"
    done

    for pkg in "${EXTRA_TOOLS[@]}"; do
        install_if_missing "$pkg" || warn "Failed to install $pkg (continuing anyway)"
    done

    install_lazygit

    setup_termux_properties
    setup_font
    setup_zsh
    setup_nvchad

    if command -v chsh >/dev/null 2>&1; then
        local current_shell
        current_shell="$(basename "$SHELL")"
        if [[ "$current_shell" != "zsh" ]]; then
            status "Changing default shell to Zsh..."
            if chsh -s "$(command -v zsh)"; then
                success "Default shell changed to Zsh"
            else
                warn "Could not change shell automatically. Run: chsh -s $(command -v zsh)"
            fi
        else
            success "Zsh is already default shell"
        fi
    else
        warn "chsh not available. To set Zsh as default: chsh -s $(command -v zsh)"
    fi

    echo ""
    print_msg "$COLOR_GREEN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_msg "$COLOR_GREEN" "✅ Setup completed successfully!"
    print_msg "$COLOR_GREEN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    status "What's next?"
    echo "  1. Restart Termux (or start a new session)."
    echo "  2. If Zsh is not your default shell, type 'zsh'."
    echo "  3. The Powerlevel10k configuration wizard will run automatically."
    echo "  4. Try the new tools:"
    echo "       la, tree, z <dir>, bat, fzf, rg, lazygit, duf, bottom, tlrc, fd"
    echo "  5. Run 'nvim' to launch NvChad."
    echo ""
    status "Optional: To use fzf key bindings (Ctrl+R), restart your shell."
}

# ----------------------------------------------------------------------
# The `termux` command (exported when sourced, run when executed)
# ----------------------------------------------------------------------
termux() {
    for opt in "$@"; do
        case "$opt" in
            -h|--help)
                usage
                return 0
                ;;
            -V|--version)
                echo "$VERSION"
                return 0
                ;;
            *)
                error "Unknown option: $opt"
                usage
                return 1
                ;;
        esac
    done
    main
}

# ----------------------------------------------------------------------
# Execute or export
# ----------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    export -f termux
else
    termux "$@"
fi