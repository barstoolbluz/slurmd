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

# ── Installer State Tracking ───────────────────────────────────────────────

INSTALLER_STATE_FILE="/etc/slurm/.installer-state"

# Record that we installed a package (for uninstall tracking).
# Usage: record_installed_package "chrony"
record_installed_package() {
    local pkg="$1"
    local state_dir
    state_dir=$(dirname "$INSTALLER_STATE_FILE")

    # Ensure directory exists
    [[ -d "$state_dir" ]] || mkdir -p "$state_dir"

    # Add header if file is new
    if [[ ! -f "$INSTALLER_STATE_FILE" ]]; then
        echo "# Installed by slurm-installer on $(date '+%Y-%m-%d %H:%M:%S')" > "$INSTALLER_STATE_FILE"
    fi

    # Record the package (uppercase, underscores)
    local key="INSTALLED_${pkg^^}"
    key="${key//-/_}"

    # Only add if not already recorded
    if ! grep -q "^${key}=" "$INSTALLER_STATE_FILE" 2>/dev/null; then
        echo "${key}=true" >> "$INSTALLER_STATE_FILE"
    fi
}

# Check if a package was installed by us.
# Usage: if was_installed_by_us "chrony"; then ...
was_installed_by_us() {
    local pkg="$1"
    local key="INSTALLED_${pkg^^}"
    key="${key//-/_}"

    [[ -f "$INSTALLER_STATE_FILE" ]] && grep -q "^${key}=true" "$INSTALLER_STATE_FILE" 2>/dev/null
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

# ── Hostname Resolution ────────────────────────────────────────────────────

# Check if a hostname is resolvable (via DNS or /etc/hosts).
# Usage: is_hostname_resolvable "hostname"
# Returns: 0 if resolvable, 1 if not
is_hostname_resolvable() {
    local hostname="$1"
    getent hosts "$hostname" &>/dev/null
}

# Add a hostname/IP mapping to /etc/hosts.
# Usage: add_to_hosts_file "192.168.1.100" "compute01"
# Skips if entry already exists.
add_to_hosts_file() {
    local ip="$1"
    local hostname="$2"
    local hosts_file="/etc/hosts"

    # Check if already present (exact hostname match on this IP)
    if grep -qE "^${ip}[[:space:]]+(.*[[:space:]]+)?${hostname}([[:space:]]|$)" "$hosts_file" 2>/dev/null; then
        log_info "${hostname} already in ${hosts_file}"
        return 0
    fi

    # Check if hostname exists with different IP
    if grep -qE "^[^#]*[[:space:]]${hostname}([[:space:]]|$)" "$hosts_file" 2>/dev/null; then
        log_warn "${hostname} exists in ${hosts_file} with different IP:"
        grep -E "^[^#]*[[:space:]]${hostname}([[:space:]]|$)" "$hosts_file" | head -1
        if ! confirm "Add new entry anyway?" "default_no"; then
            return 1
        fi
    fi

    backup_file "$hosts_file"
    echo -e "${ip}\t${hostname}" >> "$hosts_file"
    log_success "Added ${hostname} (${ip}) to ${hosts_file}"
}

# Ensure a hostname is resolvable. If not, prompt for IP and add to /etc/hosts.
# Usage: ensure_host_resolvable "compute01" ["optional context message"]
# Returns: 0 on success, 1 if user declines or invalid input
ensure_host_resolvable() {
    local hostname="$1"
    local context="${2:-}"

    # Skip if it's already an IP address
    if is_valid_ip "$hostname"; then
        return 0
    fi

    # Check if already resolvable
    if is_hostname_resolvable "$hostname"; then
        return 0
    fi

    # Not resolvable - prompt for IP
    echo
    log_warn "Cannot resolve hostname: ${hostname}"
    if [[ -n "$context" ]]; then
        echo -e "  ${context}"
    fi
    echo -e "  Slurm requires all node hostnames to be resolvable."
    echo

    if ! confirm "Add ${hostname} to /etc/hosts?" "default_yes"; then
        log_warn "Skipping — ${hostname} may not be reachable"
        return 1
    fi

    prompt_input "IP address for ${hostname}"
    local ip="$REPLY"

    if ! is_valid_ip "$ip"; then
        log_error "Invalid IP address: ${ip}"
        return 1
    fi

    add_to_hosts_file "$ip" "$hostname"
}

# ── Hardware Detection ──────────────────────────────────────────────────────

# Detect local hardware from /proc without requiring slurmd.
# Sets global variables: LOCAL_HOSTNAME, LOCAL_CPUS, LOCAL_MEMORY_MB,
#                        LOCAL_SOCKETS, LOCAL_CORES_PER_SOCKET, LOCAL_THREADS_PER_CORE
# Returns 0 on success, 1 on failure.
detect_local_hardware() {
    # Reset globals
    LOCAL_HOSTNAME=""
    LOCAL_CPUS=""
    LOCAL_MEMORY_MB=""
    LOCAL_SOCKETS=""
    LOCAL_CORES_PER_SOCKET=""
    LOCAL_THREADS_PER_CORE=""

    # Check if we're in a container (detection may reflect host hardware)
    local in_container=false
    if [[ -f /.dockerenv ]] || grep -qE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null; then
        in_container=true
    fi

    # Hostname (short form)
    LOCAL_HOSTNAME=$(hostname -s 2>/dev/null) || {
        log_warn "Could not detect hostname"
        return 1
    }
    if [[ -z "$LOCAL_HOSTNAME" ]]; then
        log_warn "Hostname is empty"
        return 1
    fi

    # CPUs (logical processors)
    if command -v nproc &>/dev/null; then
        LOCAL_CPUS=$(nproc --all 2>/dev/null)
    fi
    if [[ -z "$LOCAL_CPUS" ]] && [[ -f /proc/cpuinfo ]]; then
        LOCAL_CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    fi
    if [[ -z "$LOCAL_CPUS" || "$LOCAL_CPUS" -lt 1 ]]; then
        log_warn "Could not detect CPU count"
        return 1
    fi

    # Memory (MB)
    if [[ -f /proc/meminfo ]]; then
        LOCAL_MEMORY_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    fi
    if [[ -z "$LOCAL_MEMORY_MB" || "$LOCAL_MEMORY_MB" -lt 1 ]]; then
        log_warn "Could not detect memory size"
        return 1
    fi

    # CPU topology: sockets, cores per socket, threads per core
    # Default to 1 socket if not detectable (common in VMs)
    LOCAL_SOCKETS=1
    LOCAL_CORES_PER_SOCKET="$LOCAL_CPUS"
    LOCAL_THREADS_PER_CORE=1

    if [[ -f /proc/cpuinfo ]]; then
        # Count unique physical IDs for socket count
        local socket_count
        socket_count=$(grep '^physical id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
        if [[ -n "$socket_count" && "$socket_count" -gt 0 ]]; then
            LOCAL_SOCKETS="$socket_count"
        fi

        # Get cores per socket from cpu cores field
        local cores
        cores=$(grep -m1 '^cpu cores' /proc/cpuinfo 2>/dev/null | awk '{print $NF}')
        if [[ -n "$cores" && "$cores" -gt 0 ]]; then
            LOCAL_CORES_PER_SOCKET="$cores"
        else
            # Fallback: divide CPUs by sockets
            LOCAL_CORES_PER_SOCKET=$(( LOCAL_CPUS / LOCAL_SOCKETS ))
        fi

        # Calculate threads per core
        local total_cores=$(( LOCAL_SOCKETS * LOCAL_CORES_PER_SOCKET ))
        if [[ "$total_cores" -gt 0 ]]; then
            LOCAL_THREADS_PER_CORE=$(( LOCAL_CPUS / total_cores ))
        fi
        # Ensure at least 1 thread per core
        if [[ "$LOCAL_THREADS_PER_CORE" -lt 1 ]]; then
            LOCAL_THREADS_PER_CORE=1
        fi
    fi

    # Warn if in container
    if $in_container; then
        log_warn "Container detected — hardware values may reflect the host system."
    fi

    return 0
}

# Generate a complete NodeName line from LOCAL_* variables.
# Usage: format_nodename_line
# Output: NodeName=<hostname> CPUs=<n> RealMemory=<MB> Sockets=<n> CoresPerSocket=<n> ThreadsPerCore=<n> State=UNKNOWN
# Requires: detect_local_hardware() must be called first.
format_nodename_line() {
    # Verify all required variables are set
    if [[ -z "${LOCAL_HOSTNAME:-}" || -z "${LOCAL_CPUS:-}" || -z "${LOCAL_MEMORY_MB:-}" ]]; then
        echo ""
        return 1
    fi

    echo "NodeName=${LOCAL_HOSTNAME} CPUs=${LOCAL_CPUS} RealMemory=${LOCAL_MEMORY_MB} Sockets=${LOCAL_SOCKETS:-1} CoresPerSocket=${LOCAL_CORES_PER_SOCKET:-${LOCAL_CPUS}} ThreadsPerCore=${LOCAL_THREADS_PER_CORE:-1} State=UNKNOWN"
}

# Display detected hardware in a formatted summary box.
# Requires: detect_local_hardware() must be called first.
show_detected_hardware() {
    if [[ -z "${LOCAL_HOSTNAME:-}" || -z "${LOCAL_CPUS:-}" || -z "${LOCAL_MEMORY_MB:-}" ]]; then
        log_warn "Hardware detection not run or failed."
        return 1
    fi

    local nodename_line
    nodename_line=$(format_nodename_line)

    local lines=()
    lines+=("${BOLD}Hostname:${RESET}          ${LOCAL_HOSTNAME}")
    lines+=("${BOLD}CPUs (logical):${RESET}    ${LOCAL_CPUS}")
    lines+=("${BOLD}Memory:${RESET}            ${LOCAL_MEMORY_MB} MB")
    lines+=("${BOLD}Sockets:${RESET}           ${LOCAL_SOCKETS:-1}")
    lines+=("${BOLD}CoresPerSocket:${RESET}    ${LOCAL_CORES_PER_SOCKET:-${LOCAL_CPUS}}")
    lines+=("${BOLD}ThreadsPerCore:${RESET}    ${LOCAL_THREADS_PER_CORE:-1}")
    lines+=("")
    lines+=("${BOLD}NodeName line:${RESET}")
    lines+=("  ${CYAN}${nodename_line}${RESET}")

    print_summary "Detected Hardware" "${lines[@]}"
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

# ── Uninstall ────────────────────────────────────────────────────────────────

# Completely remove Slurm and MUNGE from this node.
# Prompts user for confirmation and options.
uninstall_slurm() {
    log_step "Uninstalling Slurm"

    # Read installer state BEFORE we might delete /etc/slurm
    local we_installed_chrony=false
    local we_installed_mariadb=false
    if [[ -f "$INSTALLER_STATE_FILE" ]]; then
        was_installed_by_us "chrony" && we_installed_chrony=true
        was_installed_by_us "mariadb-server" && we_installed_mariadb=true
    fi

    echo -e "${YELLOW}This will:${RESET}"
    echo "  - Stop all Slurm services (slurmctld, slurmdbd, slurmd, munge)"
    echo "  - Remove Slurm and MUNGE packages"
    echo "  - Optionally remove configuration files"
    echo "  - Optionally remove state/log directories"
    $we_installed_mariadb && echo "  - Optionally remove MariaDB (installed by this installer)"
    $we_installed_chrony && echo "  - Optionally remove chrony (installed by this installer)"
    echo

    if ! confirm "Proceed with uninstall?" "default_no"; then
        log_info "Uninstall cancelled."
        exit 0
    fi

    # Stop services (ignore errors if not installed)
    log_info "Stopping services..."
    for svc in slurmctld slurmdbd slurmd munge; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    log_success "Services stopped."

    # Remove packages
    log_info "Removing packages..."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y slurmd slurmctld slurmdbd slurm-client slurm-wlm-basic-plugins munge libmunge2 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
    log_success "Packages removed."

    # Config files
    if confirm "Remove configuration files (/etc/slurm, /etc/munge)?" "default_no"; then
        rm -rf /etc/slurm /etc/munge
        log_success "Configuration files removed."
    else
        log_info "Keeping configuration files."
    fi

    # State directories
    if confirm "Remove state and log directories (/var/lib/slurm, /var/log/slurm, /var/spool/slurm)?" "default_no"; then
        rm -rf /var/lib/slurm /var/log/slurm /var/spool/slurm /var/spool/slurmctld /var/spool/slurmd
        rm -rf /var/lib/munge /var/log/munge /run/munge
        log_success "State directories removed."
    else
        log_info "Keeping state directories."
    fi

    # MariaDB/slurm database
    if confirm "Drop Slurm database from MariaDB (if exists)?" "default_no"; then
        if systemctl is-active --quiet mariadb 2>/dev/null; then
            mysql -e "DROP DATABASE IF EXISTS slurm_acct_db; DROP USER IF EXISTS 'slurm'@'localhost';" 2>/dev/null || true
            log_success "Database dropped."
        else
            log_info "MariaDB not running, skipping database cleanup."
        fi
    fi

    # MariaDB (only if we installed it)
    if $we_installed_mariadb; then
        if confirm "Remove MariaDB server (installed by this installer)?" "default_no"; then
            log_info "Removing MariaDB..."
            systemctl stop mariadb 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y mariadb-server mariadb-client 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
            rm -rf /var/lib/mysql /etc/mysql
            log_success "MariaDB removed."
        fi
    fi

    # Chrony (only if we installed it)
    if $we_installed_chrony; then
        if confirm "Remove chrony (installed by this installer)?" "default_no"; then
            log_info "Removing chrony..."
            systemctl stop chrony 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y chrony 2>/dev/null || true
            log_success "Chrony removed."
        fi
    fi

    log_success "Slurm uninstall complete."
    log_info "You may now re-run the installer for a fresh setup."
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
