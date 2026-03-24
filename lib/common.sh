#!/usr/bin/env bash
# common.sh — shared functions for the Slurm installer
# Sourced by install.sh and other lib scripts; never run directly.

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
fi

# ── Logging ─────────────────────────────────────────────────────────────────

log_info()    { echo -e "${BLUE}[INFO]${RESET}    $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${RESET}   $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}>> $*${RESET}"; }

die() {
    log_error "$@"
    exit 1
}

# ── Prompts ─────────────────────────────────────────────────────────────────

# Ask a yes/no question. Returns 0 for yes, 1 for no.
# Usage: confirm "Do something?" [default_yes|default_no]
confirm() {
    local prompt="$1"
    local default="${2:-default_yes}"
    local hint

    if [[ "$default" == "default_yes" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    while true; do
        read -rp "$(echo -e "${BOLD}${prompt}${RESET} ${hint} ")" answer
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            "")
                if [[ "$default" == "default_yes" ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# Prompt for text input with an optional default.
# Usage: prompt_input "Cluster name" "mycluster"
#        Result is stored in $REPLY
prompt_input() {
    local prompt="$1"
    local default="${2:-}"

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BOLD}${prompt}${RESET} [${default}]: ")" REPLY
        REPLY="${REPLY:-$default}"
    else
        while true; do
            read -rp "$(echo -e "${BOLD}${prompt}${RESET}: ")" REPLY
            if [[ -n "$REPLY" ]]; then
                break
            fi
            echo "A value is required."
        done
    fi
}

# Prompt for a password (hidden input) with optional default.
# Usage: prompt_password "MariaDB password" "changeme"
#        Result is stored in $REPLY
prompt_password() {
    local prompt="$1"
    local default="${2:-}"

    if [[ -n "$default" ]]; then
        read -rsp "$(echo -e "${BOLD}${prompt}${RESET} [hidden, enter for default]: ")" REPLY
        echo
        REPLY="${REPLY:-$default}"
    else
        while true; do
            read -rsp "$(echo -e "${BOLD}${prompt}${RESET}: ")" REPLY
            echo
            if [[ -n "$REPLY" ]]; then
                break
            fi
            echo "A value is required."
        done
    fi
}

# Display a numbered menu and prompt for selection.
# Usage: menu_select "Choose a role:" "Option A" "Option B" "Option C"
#        Result (1-based index) is stored in $REPLY
menu_select() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}

    echo -e "\n${BOLD}${prompt}${RESET}"
    for i in "${!options[@]}"; do
        echo -e "  ${CYAN}$((i + 1)))${RESET} ${options[$i]}"
    done
    echo

    while true; do
        read -rp "$(echo -e "${BOLD}Enter choice [1-${count}]:${RESET} ")" REPLY
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= count )); then
            return 0
        fi
        echo "Please enter a number between 1 and ${count}."
    done
}

# ── Validation ──────────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

require_debian() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS — /etc/os-release not found."
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    if [[ "${ID:-}" != "debian" ]]; then
        die "This installer only supports Debian. Detected: ${PRETTY_NAME:-unknown}"
    fi

    DEBIAN_VERSION="${VERSION_ID:-unknown}"
    DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"

    case "$DEBIAN_VERSION" in
        11|12|13)
            log_info "Detected Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
            ;;
        *)
            log_warn "Detected Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME}) — not tested, proceed with caution."
            if ! confirm "Continue anyway?" "default_no"; then
                exit 1
            fi
            ;;
    esac
}

is_valid_hostname() {
    local name="$1"
    # RFC 1123: alphanumeric, hyphens, dots; 1-253 chars; labels 1-63 chars
    [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?$ ]]
}

is_valid_ip() {
    local ip="$1"
    local IFS='.'
    # shellcheck disable=SC2206
    local octets=($ip)
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

# ── Utility ─────────────────────────────────────────────────────────────────

# Back up a file before modifying it.
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$file" "$backup"
        log_info "Backed up ${file} -> ${backup}"
    fi
}

# Render a template file by replacing %%VAR%% placeholders with values
# from an associative array.
# Usage:
#   declare -A vars=( [CLUSTER_NAME]="mycluster" [CONTROLLER]="head1" )
#   render_template "input.tmpl" "output.conf" vars
render_template() {
    local template="$1"
    local output="$2"
    local -n _vars="$3"

    if [[ ! -f "$template" ]]; then
        die "Template not found: ${template}"
    fi

    local content
    content=$(cat "$template")

    for key in "${!_vars[@]}"; do
        content="${content//%%${key}%%/${_vars[$key]}}"
    done

    printf '%s\n' "$content" > "$output"
}

# Check if a systemd service is active.
is_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# Check if a systemd service is enabled.
is_service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# Enable and start a systemd service.
enable_and_start() {
    local service="$1"
    log_info "Enabling and starting ${service}..."
    systemctl enable "$service" || {
        log_error "Failed to enable ${service}. Check: systemctl status ${service}"
        return 1
    }
    systemctl start "$service" || true
    # Give the service a moment to settle, then check
    sleep 1
    if is_service_active "$service"; then
        log_success "${service} is running."
    else
        log_error "${service} failed to start. Check: journalctl -xeu ${service}"
        return 1
    fi
}

# Install packages via apt, skipping already-installed ones.
apt_install() {
    local packages=("$@")
    log_info "Installing packages: ${packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${packages[@]}"
}

# Ensure apt cache is reasonably fresh (updated within last hour).
apt_update_if_stale() {
    local stamp="/var/lib/apt/periodic/update-success-stamp"
    local age=3600  # 1 hour

    if [[ ! -f "$stamp" ]] || (( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) > age )); then
        log_info "Updating apt package cache..."
        apt-get update -q
    fi
}

# Print a summary box.
print_summary() {
    local title="$1"
    shift
    local lines=("$@")
    local width=60

    local rule
    rule=$(printf '%0.s-' $(seq 1 "$width"))

    echo
    echo -e "${BOLD}${CYAN}${rule}${RESET}"
    echo -e "${BOLD}${CYAN} ${title}${RESET}"
    echo -e "${BOLD}${CYAN}${rule}${RESET}"
    for line in "${lines[@]}"; do
        echo -e "  ${line}"
    done
    echo -e "${BOLD}${CYAN}${rule}${RESET}"
    echo
}
