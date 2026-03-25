#!/usr/bin/env bash
# ===========================================================================
# install.sh — Interactive Slurm installer for Debian systems
# ===========================================================================
# Usage: sudo ./install.sh [--setup-nodes|--uninstall]
#
# This script walks you through installing and configuring Slurm on a
# Debian node. It supports the following node roles:
#
#   1) Controller + Database  — All-in-one head node (small clusters)
#   2) Controller only        — Separate head node (DB elsewhere)
#   3) Database only          — Dedicated accounting DB node
#   4) Compute node           — Worker that executes jobs
#   5) Login node             — User-facing, client tools only
#
# Options:
#   --setup-nodes    After controller setup, distribute config files to
#                    compute/login nodes via SSH (requires key-based auth)
#   --uninstall      Remove Slurm and MUNGE from this node
#
# Requires: Debian 11+, root privileges, network access to apt repos.
# ===========================================================================

set -euo pipefail
umask 0077

# Resolve the directory this script lives in (for finding lib/ and config/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load library scripts ──────────────────────────────────────────────────

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/prereqs.sh"
source "${SCRIPT_DIR}/lib/munge.sh"
source "${SCRIPT_DIR}/lib/database.sh"
source "${SCRIPT_DIR}/lib/controller.sh"
source "${SCRIPT_DIR}/lib/compute.sh"
source "${SCRIPT_DIR}/lib/login.sh"

# ── Distribute configs to remote nodes ────────────────────────────────────

# SSH connection mode globals
SSH_USER=""        # Username for SSH
SSH_MODE=""        # "root" | "sudo_passwordless" | "sudo_password"

# Controller also acting as compute node
CONTROLLER_IS_COMPUTE=false
CONTROLLER_NODENAME=""

# Prompt user to select SSH connection mode.
# Sets SSH_USER and SSH_MODE globals.
select_ssh_mode() {
    echo
    menu_select "How do you connect to cluster nodes?" \
        "As root directly (SSH as root@node)" \
        "As a regular user with passwordless sudo (recommended)" \
        "As a regular user with sudo (password prompt)"

    case "$REPLY" in
        1)
            SSH_USER="root"
            SSH_MODE="root"
            log_info "Will connect as root@<node>"
            ;;
        2)
            SSH_MODE="sudo_passwordless"
            local default_user
            default_user=$(whoami)
            prompt_input "SSH username" "$default_user"
            SSH_USER="$REPLY"
            log_info "Will connect as ${SSH_USER}@<node> with passwordless sudo"
            ;;
        3)
            SSH_MODE="sudo_password"
            local default_user
            default_user=$(whoami)
            prompt_input "SSH username" "$default_user"
            SSH_USER="$REPLY"
            log_info "Will connect as ${SSH_USER}@<node> with sudo (password prompt)"
            ;;
    esac
}

# Run a command locally, using sudo if not root.
# Usage: local_sudo command [args...]
local_sudo() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Read a file locally, using sudo if needed.
# Usage: local_read_file "/etc/munge/munge.key"
local_read_file() {
    local file="$1"
    if [[ -r "$file" ]]; then
        cat "$file"
    else
        sudo cat "$file"
    fi
}

# Check if this machine is a Slurm controller (has slurmctld installed/configured).
is_controller_node() {
    # Check if slurmctld service unit file exists
    if systemctl list-unit-files slurmctld.service 2>/dev/null | grep -q 'slurmctld\.service'; then
        return 0
    fi
    return 1
}

# Add compute node definitions to an existing slurm.conf.
# Usage: add_nodes_to_slurm_conf "NodeName=node1 CPUs=8 ..."
# Multiple nodes can be passed as newline-separated string.
add_nodes_to_slurm_conf() {
    local new_nodes="$1"
    local conf_file="/etc/slurm/slurm.conf"
    local partition_name="${PARTITION_NAME:-batch}"

    if [[ -z "$new_nodes" ]]; then
        log_warn "No nodes to add."
        return 1
    fi

    # Read current config
    local conf_content
    conf_content=$(local_read_file "$conf_file") || {
        log_error "Could not read slurm.conf"
        return 1
    }

    # Backup first
    backup_file "$conf_file"

    # Extract node names for partition
    local node_names
    node_names=$(echo "$new_nodes" | grep -oP 'NodeName=\K[^\s]+' | paste -sd',' -)

    # Check if we have placeholder comments (no real nodes defined yet)
    if echo "$conf_content" | grep -q '^# No compute nodes configured yet\.'; then
        # Replace placeholder block with actual nodes
        # The range matches from "# No compute nodes configured yet." to the example NodeName line
        conf_content=$(echo "$conf_content" | sed '/^# No compute nodes configured yet\./,/^# NodeName=compute01.*State=UNKNOWN/d')
        # Also update the commented partition line
        conf_content=$(echo "$conf_content" | sed "s|^# PartitionName=batch Nodes=compute\[01-10\].*|PartitionName=${partition_name} Nodes=${node_names} Default=YES MaxTime=INFINITE State=UP|")
    else
        # Nodes already exist - combine existing node names with new ones
        local existing_names
        existing_names=$(echo "$conf_content" | grep -oP '^NodeName=\K[^\s]+' | paste -sd',' -)
        local new_names
        new_names=$(echo "$new_nodes" | grep -oP 'NodeName=\K[^\s]+' | paste -sd',' -)
        if [[ -n "$existing_names" ]]; then
            node_names="${existing_names},${new_names}"
        else
            node_names="${new_names}"
        fi
        # Update partition to include all nodes
        conf_content=$(echo "$conf_content" | sed -E "s|^(PartitionName=${partition_name} Nodes=)[^ ]+|\1${node_names}|")
    fi

    # Find where to insert nodes (before partition section)
    local temp_file
    temp_file=$(mktemp)

    # Write config with new nodes inserted
    local nodes_written=false
    while IFS= read -r line; do
        # Detect start of partition section
        if [[ "$line" =~ ^#\ ──\ Partitions ]] && ! $nodes_written; then
            # Insert new nodes before partition section
            echo "$new_nodes"
            echo
            nodes_written=true
        fi
        echo "$line"
    done <<< "$conf_content" > "$temp_file"

    # If nodes weren't written (no partition section marker), append them
    if ! $nodes_written; then
        echo "$new_nodes" >> "$temp_file"
    fi

    # Check for GPU nodes and update GresTypes if needed
    if echo "$new_nodes" | grep -qE 'Gres=gpu'; then
        if ! grep -q '^GresTypes=gpu' "$temp_file"; then
            # Replace commented GresTypes line
            sed -i 's|^# GresTypes=gpu.*|GresTypes=gpu|' "$temp_file"
        fi
    fi

    # Move temp file to conf
    local_sudo mv "$temp_file" "$conf_file"
    local_sudo chown root:root "$conf_file"
    local_sudo chmod 0644 "$conf_file"

    log_success "Added $(echo "$new_nodes" | wc -l) node(s) to slurm.conf"
    return 0
}

# Extract simple hostnames from slurm.conf NodeName entries.
# Skips node ranges like node[01-10] and the local hostname.
get_remote_nodes() {
    local conf_file="/etc/slurm/slurm.conf"
    local local_host
    local_host=$(hostname -s)

    # Read config file (may need sudo)
    local conf_content
    conf_content=$(local_read_file "$conf_file" 2>/dev/null) || return 1

    local node
    for node in $(echo "$conf_content" | grep -oP '^NodeName=\K[^[:space:]]+'); do
        # Skip node ranges (contain brackets)
        if [[ "$node" =~ \[ ]]; then
            continue
        fi
        # Skip local host
        if [[ "$node" == "$local_host" ]]; then
            continue
        fi
        echo "$node"
    done
}

# Display current node configurations from slurm.conf.
show_existing_nodes() {
    local conf_content
    conf_content=$(local_read_file /etc/slurm/slurm.conf) || return 1

    echo
    log_info "Current compute nodes in slurm.conf:"
    echo

    while IFS= read -r line; do
        local nodename
        nodename=$(echo "$line" | grep -oP 'NodeName=\K[^\s]+')
        echo -e "  ${CYAN}${nodename}${RESET}"
        echo -e "    ${line}"
    done < <(echo "$conf_content" | grep -E '^NodeName=')
    echo
}

# Fetch hardware config from remote node via SSH.
# Usage: fetch_node_hardware "hostname"
# Returns: NodeName line from slurmd -C, or empty on failure.
# Requires: SSH_MODE and SSH_USER globals to be set.
fetch_node_hardware() {
    local node="$1"
    local ssh_target="${SSH_USER}@${node}"
    local hw_line=""
    local slurmd_cmd="/usr/sbin/slurmd -C 2>/dev/null | head -1"

    case "$SSH_MODE" in
        root)
            hw_line=$(ssh -q -o BatchMode=yes -o ConnectTimeout=10 \
                "root@${node}" "$slurmd_cmd" 2>/dev/null) || return 1
            ;;
        sudo_passwordless)
            hw_line=$(ssh -q -o BatchMode=yes -o ConnectTimeout=10 \
                "$ssh_target" "sudo $slurmd_cmd" 2>/dev/null) || return 1
            ;;
        sudo_password)
            hw_line=$(ssh -o ConnectTimeout=10 \
                "$ssh_target" "sudo $slurmd_cmd" 2>/dev/null) || return 1
            ;;
    esac

    # Validate output
    if [[ -z "$hw_line" || ! "$hw_line" =~ ^NodeName= ]]; then
        return 1
    fi

    echo "$hw_line"
}

# Update a node's configuration in slurm.conf.
# Usage: update_node_config "nodename" "new NodeName=... line"
update_node_config() {
    local nodename="$1"
    local new_line="$2"
    local conf_file="/etc/slurm/slurm.conf"

    # Backup first
    backup_file "$conf_file"

    # Use awk for replacement - safer than sed with special characters
    # Exact match on first field avoids regex issues with dots in FQDNs
    local_sudo awk -v target="NodeName=${nodename}" -v newline="$new_line" '
        $1 == target { print newline; next }
        { print }
    ' "$conf_file" > "${conf_file}.tmp" && local_sudo mv "${conf_file}.tmp" "$conf_file"

    log_success "Updated ${nodename} in slurm.conf"
}

# Interactive review and update of existing node configurations.
# Usage: review_node_configs "node1\nnode2\n..."
# Requires: SSH_MODE and SSH_USER globals to be set.
review_node_configs() {
    local nodes="$1"
    local changes_made=false

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue

        # Get current config (escape dots in node name for regex - FQDNs contain dots)
        local node_escaped="${node//./\\.}"
        local current_line
        current_line=$(local_read_file /etc/slurm/slurm.conf | grep -E "^NodeName=${node_escaped}[[:space:]]")

        echo
        echo -e "${BOLD}Node: ${node}${RESET}"
        echo -e "  Current config:"
        echo -e "    ${current_line}"
        echo

        menu_select "Action for ${node}:" \
            "Keep current configuration" \
            "Update via SSH (run slurmd -C on ${node})" \
            "Enter new configuration manually"

        case "$REPLY" in
            1)
                log_info "Keeping current config for ${node}"
                ;;
            2)
                log_info "Fetching hardware info from ${node}..."
                local new_line
                if new_line=$(fetch_node_hardware "$node"); then
                    echo -e "  Detected:"
                    echo -e "    ${CYAN}${new_line}${RESET}"
                    echo
                    if confirm "Apply this configuration?" "default_yes"; then
                        update_node_config "$node" "$new_line"
                        changes_made=true
                    fi
                else
                    log_error "Could not fetch hardware from ${node}"
                    log_info "Ensure slurmd is installed and SSH access works."
                fi
                ;;
            3)
                echo
                echo -e "Enter new NodeName line for ${node}:"
                echo -e "  (Paste output from 'slurmd -C' on the node)"
                read -rp "Config> " new_line
                if [[ "$new_line" =~ ^NodeName= ]]; then
                    update_node_config "$node" "$new_line"
                    changes_made=true
                else
                    log_warn "Invalid format — must start with NodeName="
                fi
                ;;
        esac
    done <<< "$nodes"

    if $changes_made; then
        echo
        log_info "Reconfiguring slurmctld to apply changes..."
        if local_sudo scontrol reconfigure 2>/dev/null; then
            log_success "Controller reconfigured."
        else
            log_warn "Could not reconfigure controller. Run 'scontrol reconfigure' manually."
        fi
    fi
}

# Test SSH connectivity to a node and report issues.
# Usage: test_ssh_connectivity "hostname"
# Returns 0 if OK, 1 if failed (with helpful error message).
test_ssh_connectivity() {
    local node="$1"
    local ssh_target="${SSH_USER}@${node}"
    local ssh_err

    # For sudo_password mode, user may not have SSH keys - use interactive test
    if [[ "$SSH_MODE" == "sudo_password" ]]; then
        echo -e "  Testing ${node}... (you may be prompted for your password)"
        if ! ssh -o ConnectTimeout=10 "$ssh_target" 'echo ok' &>/dev/null; then
            log_error "  ${node}: SSH connection failed"
            log_info "    Check that you can: ssh ${ssh_target}"
            return 1
        fi
        return 0
    fi

    # For key-based modes, use BatchMode to verify keys work
    if ! ssh_err=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" 'echo ok' 2>&1); then
        if [[ "$ssh_err" == *"Host key verification"* ]]; then
            log_error "  ${node}: Host key not accepted"
            log_info "    Fix: ssh ${ssh_target}  (accept the key, then retry)"
        elif [[ "$ssh_err" == *"Permission denied"* ]]; then
            log_error "  ${node}: SSH key authentication failed"
            log_info "    Fix: ssh-copy-id ${ssh_target}"
        elif [[ "$ssh_err" == *"Could not resolve"* || "$ssh_err" == *"Name or service not known"* ]]; then
            log_error "  ${node}: Hostname not found"
            log_info "    Fix: Add ${node} to /etc/hosts or DNS"
        elif [[ "$ssh_err" == *"Connection refused"* ]]; then
            log_error "  ${node}: Connection refused (SSH not running?)"
        elif [[ "$ssh_err" == *"Connection timed out"* || "$ssh_err" == *"timed out"* ]]; then
            log_error "  ${node}: Connection timed out (network issue?)"
        else
            log_error "  ${node}: SSH failed - ${ssh_err}"
        fi
        return 1
    fi
    return 0
}

# Copy config files to a single remote node.
# Usage: distribute_to_node "hostname"
# Uses SSH_USER and SSH_MODE globals to determine connection mode.
distribute_to_node() {
    local node="$1"
    local failed=false

    log_info "Distributing to ${node}..."

    case "$SSH_MODE" in
        root)
            distribute_to_node_root "$node" || failed=true
            ;;
        sudo_passwordless)
            distribute_to_node_sudo_passwordless "$node" || failed=true
            ;;
        sudo_password)
            distribute_to_node_sudo_password "$node" || failed=true
            ;;
        *)
            log_error "  Internal error: invalid SSH_MODE '${SSH_MODE}'"
            failed=true
            ;;
    esac

    if $failed; then
        return 1
    fi

    log_success "  ${node} — done"
    return 0
}

# Distribute files using direct root SSH (original method).
# If running locally as non-root, uses sudo to read files first.
distribute_to_node_root() {
    local node="$1"
    local ssh_target="root@${node}"
    local failed=false

    # If running as non-root locally, we need to stage files first
    if [[ $EUID -ne 0 ]]; then
        local local_tmp
        local_tmp=$(mktemp -d)
        trap "rm -rf '$local_tmp'" RETURN

        local_read_file /etc/munge/munge.key > "${local_tmp}/munge.key" || {
            log_error "  Failed to read local munge.key"
            return 1
        }
        local_read_file /etc/slurm/slurm.conf > "${local_tmp}/slurm.conf" || {
            log_error "  Failed to read local slurm.conf"
            return 1
        }
        if local_sudo test -f /etc/slurm/cgroup.conf 2>/dev/null; then
            local_read_file /etc/slurm/cgroup.conf > "${local_tmp}/cgroup.conf"
        fi
        if local_sudo test -f /etc/slurm/gres.conf 2>/dev/null; then
            local_read_file /etc/slurm/gres.conf > "${local_tmp}/gres.conf"
        fi

        # Copy from temp files
        if ! scp -q -o BatchMode=yes "${local_tmp}/munge.key" "${ssh_target}:/etc/munge/munge.key" 2>/dev/null; then
            log_error "  Failed to copy munge.key to ${node}"
            failed=true
        fi
        if ! scp -q -o BatchMode=yes "${local_tmp}/slurm.conf" "${ssh_target}:/etc/slurm/slurm.conf" 2>/dev/null; then
            log_error "  Failed to copy slurm.conf to ${node}"
            failed=true
        fi
        if [[ -f "${local_tmp}/cgroup.conf" ]]; then
            if ! scp -q -o BatchMode=yes "${local_tmp}/cgroup.conf" "${ssh_target}:/etc/slurm/cgroup.conf" 2>/dev/null; then
                log_error "  Failed to copy cgroup.conf to ${node}"
                failed=true
            fi
        fi
        if [[ -f "${local_tmp}/gres.conf" ]]; then
            if ! scp -q -o BatchMode=yes "${local_tmp}/gres.conf" "${ssh_target}:/etc/slurm/gres.conf" 2>/dev/null; then
                log_error "  Failed to copy gres.conf to ${node}"
                failed=true
            fi
        fi
    else
        # Running as root locally - direct copy
        if ! scp -q -o BatchMode=yes /etc/munge/munge.key "${ssh_target}:/etc/munge/munge.key" 2>/dev/null; then
            log_error "  Failed to copy munge.key to ${node}"
            failed=true
        fi
        if ! scp -q -o BatchMode=yes /etc/slurm/slurm.conf "${ssh_target}:/etc/slurm/slurm.conf" 2>/dev/null; then
            log_error "  Failed to copy slurm.conf to ${node}"
            failed=true
        fi
        if [[ -f /etc/slurm/cgroup.conf ]]; then
            if ! scp -q -o BatchMode=yes /etc/slurm/cgroup.conf "${ssh_target}:/etc/slurm/cgroup.conf" 2>/dev/null; then
                log_error "  Failed to copy cgroup.conf to ${node}"
                failed=true
            fi
        fi
        if [[ -f /etc/slurm/gres.conf ]]; then
            if ! scp -q -o BatchMode=yes /etc/slurm/gres.conf "${ssh_target}:/etc/slurm/gres.conf" 2>/dev/null; then
                log_error "  Failed to copy gres.conf to ${node}"
                failed=true
            fi
        fi
    fi

    # Set munge key permissions (always needed)
    if ! ssh -q -o BatchMode=yes "$ssh_target" 'chown munge:munge /etc/munge/munge.key && chmod 0400 /etc/munge/munge.key' 2>/dev/null; then
        log_error "  Failed to set munge.key permissions on ${node}"
        failed=true
    fi

    # Restart munge and slurmd on remote node to pick up new key/config
    if ! $failed; then
        ssh -q -o BatchMode=yes "$ssh_target" 'systemctl restart munge && (systemctl restart slurmd 2>/dev/null || true)' 2>/dev/null || {
            log_warn "  Failed to restart services on ${node} — may need manual restart"
        }
    fi

    $failed && return 1
    return 0
}

# Distribute files using regular user SSH + passwordless sudo (BatchMode).
distribute_to_node_sudo_passwordless() {
    local node="$1"
    local ssh_target="${SSH_USER}@${node}"
    local failed=false
    local tmp_dir="/tmp/slurm-dist.$$"

    # Create local temp dir for files we may need to read with sudo
    local local_tmp
    local_tmp=$(mktemp -d)
    trap "rm -rf '$local_tmp'" RETURN

    # Read files locally (may need sudo)
    local_read_file /etc/munge/munge.key > "${local_tmp}/munge.key" || {
        log_error "  Failed to read local munge.key"
        return 1
    }
    local_read_file /etc/slurm/slurm.conf > "${local_tmp}/slurm.conf" || {
        log_error "  Failed to read local slurm.conf"
        return 1
    }
    if local_sudo test -f /etc/slurm/cgroup.conf 2>/dev/null; then
        local_read_file /etc/slurm/cgroup.conf > "${local_tmp}/cgroup.conf" || {
            log_error "  Failed to read local cgroup.conf"
            return 1
        }
    fi
    if local_sudo test -f /etc/slurm/gres.conf 2>/dev/null; then
        local_read_file /etc/slurm/gres.conf > "${local_tmp}/gres.conf" || {
            log_error "  Failed to read local gres.conf"
            return 1
        }
    fi

    # Create temp directory on remote
    if ! ssh -q -o BatchMode=yes "$ssh_target" "mkdir -p ${tmp_dir}" 2>/dev/null; then
        log_error "  Failed to create temp directory on ${node}"
        return 1
    fi

    # Copy files to temp location on remote
    if ! scp -q -o BatchMode=yes "${local_tmp}/munge.key" "${ssh_target}:${tmp_dir}/munge.key" 2>/dev/null; then
        log_error "  Failed to copy munge.key to ${node}"
        failed=true
    fi

    if ! scp -q -o BatchMode=yes "${local_tmp}/slurm.conf" "${ssh_target}:${tmp_dir}/slurm.conf" 2>/dev/null; then
        log_error "  Failed to copy slurm.conf to ${node}"
        failed=true
    fi

    if [[ -f "${local_tmp}/cgroup.conf" ]]; then
        if ! scp -q -o BatchMode=yes "${local_tmp}/cgroup.conf" "${ssh_target}:${tmp_dir}/cgroup.conf" 2>/dev/null; then
            log_error "  Failed to copy cgroup.conf to ${node}"
            failed=true
        fi
    fi

    if [[ -f "${local_tmp}/gres.conf" ]]; then
        if ! scp -q -o BatchMode=yes "${local_tmp}/gres.conf" "${ssh_target}:${tmp_dir}/gres.conf" 2>/dev/null; then
            log_error "  Failed to copy gres.conf to ${node}"
            failed=true
        fi
    fi

    # Use sudo to move files to final locations and restart services (passwordless - BatchMode)
    local remote_cmd="
        sudo mv ${tmp_dir}/munge.key /etc/munge/munge.key &&
        sudo chown munge:munge /etc/munge/munge.key &&
        sudo chmod 0400 /etc/munge/munge.key &&
        sudo mv ${tmp_dir}/slurm.conf /etc/slurm/slurm.conf &&
        sudo chown root:root /etc/slurm/slurm.conf &&
        sudo chmod 0644 /etc/slurm/slurm.conf"

    if [[ -f "${local_tmp}/cgroup.conf" ]]; then
        remote_cmd="${remote_cmd} &&
        sudo mv ${tmp_dir}/cgroup.conf /etc/slurm/cgroup.conf &&
        sudo chown root:root /etc/slurm/cgroup.conf &&
        sudo chmod 0644 /etc/slurm/cgroup.conf"
    fi

    if [[ -f "${local_tmp}/gres.conf" ]]; then
        remote_cmd="${remote_cmd} &&
        sudo mv ${tmp_dir}/gres.conf /etc/slurm/gres.conf &&
        sudo chown root:root /etc/slurm/gres.conf &&
        sudo chmod 0644 /etc/slurm/gres.conf"
    fi

    # Restart services after file installation
    remote_cmd="${remote_cmd} &&
        rm -rf ${tmp_dir} &&
        sudo systemctl restart munge &&
        (sudo systemctl restart slurmd 2>/dev/null || true)"

    if ! ssh -q -o BatchMode=yes "$ssh_target" "$remote_cmd" 2>/dev/null; then
        log_error "  Failed to install files on ${node} (passwordless sudo may not be configured)"
        log_info "    Test with: ssh ${ssh_target} 'sudo whoami'"
        failed=true
        ssh -q -o BatchMode=yes "$ssh_target" "rm -rf '${tmp_dir}'" 2>/dev/null || true
    fi

    $failed && return 1
    return 0
}

# Distribute files using regular user SSH + sudo with password prompt.
distribute_to_node_sudo_password() {
    local node="$1"
    local ssh_target="${SSH_USER}@${node}"
    local failed=false
    local tmp_dir="/tmp/slurm-dist.$$"

    # Create local temp dir for files we may need to read with sudo
    local local_tmp
    local_tmp=$(mktemp -d)

    # Set up SSH connection multiplexing to avoid multiple password prompts
    local ssh_socket="${local_tmp}/ssh-socket"
    local ssh_opts="-o ControlMaster=auto -o ControlPath=${ssh_socket} -o ControlPersist=60"

    # Cleanup: close SSH connection and remove temp files
    # Note: variables are expanded now (at trap setup time) to avoid scope issues
    trap "ssh -q -o ControlPath='${ssh_socket}' -O exit '${ssh_target}' 2>/dev/null || true; rm -rf '${local_tmp}'" RETURN

    # Read files locally (may need sudo)
    local_read_file /etc/munge/munge.key > "${local_tmp}/munge.key" || {
        log_error "  Failed to read local munge.key"
        return 1
    }
    local_read_file /etc/slurm/slurm.conf > "${local_tmp}/slurm.conf" || {
        log_error "  Failed to read local slurm.conf"
        return 1
    }
    if local_sudo test -f /etc/slurm/cgroup.conf 2>/dev/null; then
        local_read_file /etc/slurm/cgroup.conf > "${local_tmp}/cgroup.conf" || {
            log_error "  Failed to read local cgroup.conf"
            return 1
        }
    fi
    if local_sudo test -f /etc/slurm/gres.conf 2>/dev/null; then
        local_read_file /etc/slurm/gres.conf > "${local_tmp}/gres.conf" || {
            log_error "  Failed to read local gres.conf"
            return 1
        }
    fi

    # Establish master SSH connection (will prompt for password once)
    log_info "  Connecting to ${node} (you will be prompted for your password once)..."
    if ! ssh -q $ssh_opts "$ssh_target" "mkdir -p ${tmp_dir}"; then
        log_error "  Failed to connect to ${node}"
        return 1
    fi

    # Copy files to temp location on remote (reuses master connection)
    if ! scp -q $ssh_opts "${local_tmp}/munge.key" "${ssh_target}:${tmp_dir}/munge.key"; then
        log_error "  Failed to copy munge.key to ${node}"
        failed=true
    fi

    if ! scp -q $ssh_opts "${local_tmp}/slurm.conf" "${ssh_target}:${tmp_dir}/slurm.conf"; then
        log_error "  Failed to copy slurm.conf to ${node}"
        failed=true
    fi

    if [[ -f "${local_tmp}/cgroup.conf" ]]; then
        if ! scp -q $ssh_opts "${local_tmp}/cgroup.conf" "${ssh_target}:${tmp_dir}/cgroup.conf"; then
            log_error "  Failed to copy cgroup.conf to ${node}"
            failed=true
        fi
    fi

    if [[ -f "${local_tmp}/gres.conf" ]]; then
        if ! scp -q $ssh_opts "${local_tmp}/gres.conf" "${ssh_target}:${tmp_dir}/gres.conf"; then
            log_error "  Failed to copy gres.conf to ${node}"
            failed=true
        fi
    fi

    # Get controller info for hostname resolution
    # Use hostname from slurm.conf to ensure we resolve what Slurm expects
    local controller_hostname
    controller_hostname=$(get_controller_hostname_from_conf) || controller_hostname=$(hostname -s)
    local controller_ip
    controller_ip=$(hostname -I | awk '{print $1}')

    # Create remote install script (avoids quoting issues with ssh -tt)
    local remote_script="${tmp_dir}/install.sh"
    local script_content
    script_content="#!/bin/bash
set -e
# Ensure controller hostname is resolvable
if ! getent hosts ${controller_hostname} >/dev/null 2>&1; then
    echo '${controller_ip}	${controller_hostname}' | sudo tee -a /etc/hosts >/dev/null
fi
sudo mv ${tmp_dir}/munge.key /etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key
sudo mv ${tmp_dir}/slurm.conf /etc/slurm/slurm.conf
sudo chown root:root /etc/slurm/slurm.conf
sudo chmod 0644 /etc/slurm/slurm.conf"

    if [[ -f "${local_tmp}/cgroup.conf" ]]; then
        script_content="${script_content}
sudo mv ${tmp_dir}/cgroup.conf /etc/slurm/cgroup.conf
sudo chown root:root /etc/slurm/cgroup.conf
sudo chmod 0644 /etc/slurm/cgroup.conf"
    fi

    if [[ -f "${local_tmp}/gres.conf" ]]; then
        script_content="${script_content}
sudo mv ${tmp_dir}/gres.conf /etc/slurm/gres.conf
sudo chown root:root /etc/slurm/gres.conf
sudo chmod 0644 /etc/slurm/gres.conf"
    fi

    # Add service restarts to the script
    script_content="${script_content}
rm -rf ${tmp_dir}
sudo systemctl restart munge
sudo systemctl restart slurmd 2>/dev/null || true"

    if ! echo "$script_content" | ssh -q $ssh_opts "$ssh_target" "cat > ${remote_script} && chmod +x ${remote_script}"; then
        log_error "  Failed to create install script on ${node}"
        failed=true
        ssh -q $ssh_opts "$ssh_target" "rm -rf '${tmp_dir}'" 2>/dev/null || true
        return 1
    fi

    log_info "  Installing files (sudo password required)..."
    if ! ssh -tt $ssh_opts "$ssh_target" "${remote_script}" </dev/tty; then
        log_error "  Failed to install files on ${node}"
        failed=true
        ssh -q $ssh_opts "$ssh_target" "rm -rf '${tmp_dir}'" 2>/dev/null || true
    fi

    $failed && return 1
    return 0
}

# Get controller hostname from slurm.conf SlurmctldHost directive.
# Returns the hostname (without backup specification).
# Returns 1 (failure) if not found or empty.
get_controller_hostname_from_conf() {
    local conf_content
    conf_content=$(local_read_file /etc/slurm/slurm.conf 2>/dev/null) || return 1
    # Extract SlurmctldHost value, strip any (backup) specification
    local ctrl_host
    ctrl_host=$(echo "$conf_content" | grep -oP '^SlurmctldHost=\K[^(\s]+' | head -1)
    # Return failure if empty
    if [[ -z "$ctrl_host" ]]; then
        return 1
    fi
    echo "$ctrl_host"
}

# Ensure a remote node can resolve the controller hostname.
# Adds controller to remote /etc/hosts if needed.
# Usage: setup_remote_hostname_resolution "hostname"
setup_remote_hostname_resolution() {
    local node="$1"
    local ssh_target="${SSH_USER}@${node}"
    local controller_hostname
    # Use hostname from slurm.conf to ensure we resolve what Slurm expects
    controller_hostname=$(get_controller_hostname_from_conf) || controller_hostname=$(hostname -s)
    local controller_ip
    controller_ip=$(hostname -I | awk '{print $1}')

    # Check if remote can already resolve controller
    case "$SSH_MODE" in
        root)
            if ssh -q -o BatchMode=yes "root@${node}" "getent hosts ${controller_hostname}" &>/dev/null; then
                return 0  # Already resolvable
            fi
            log_info "  Adding ${controller_hostname} to /etc/hosts on ${node}..."
            ssh -q -o BatchMode=yes "root@${node}" \
                "echo '${controller_ip}	${controller_hostname}' >> /etc/hosts" 2>/dev/null || {
                log_warn "  Failed to update /etc/hosts on ${node}"
                return 1
            }
            ;;
        sudo_passwordless)
            if ssh -q -o BatchMode=yes "$ssh_target" "getent hosts ${controller_hostname}" &>/dev/null; then
                return 0  # Already resolvable
            fi
            log_info "  Adding ${controller_hostname} to /etc/hosts on ${node}..."
            ssh -q -o BatchMode=yes "$ssh_target" \
                "echo '${controller_ip}	${controller_hostname}' | sudo tee -a /etc/hosts >/dev/null" 2>/dev/null || {
                log_warn "  Failed to update /etc/hosts on ${node}"
                return 1
            }
            ;;
        sudo_password)
            # For password sudo, we'll handle this in the distribute script
            # Just check if resolvable
            if ssh -q -o BatchMode=yes "$ssh_target" "getent hosts ${controller_hostname}" &>/dev/null; then
                return 0
            fi
            # Will be handled by the distribute function
            ;;
    esac
    return 0
}

# Verify munge authentication to a remote node.
# Usage: verify_munge_to_node "hostname"
# Returns 0 if OK, 1 if failed.
verify_munge_to_node() {
    local node="$1"
    local ssh_target="${SSH_USER}@${node}"

    # Generate credential locally, decode remotely
    # This tests the full munge key chain
    case "$SSH_MODE" in
        root)
            if munge -n 2>/dev/null | ssh -q -o BatchMode=yes "root@${node}" 'unmunge' &>/dev/null; then
                return 0
            fi
            ;;
        sudo_passwordless)
            if munge -n 2>/dev/null | ssh -q -o BatchMode=yes "$ssh_target" 'unmunge' &>/dev/null; then
                return 0
            fi
            ;;
        sudo_password)
            # Can't easily do this in BatchMode with password sudo
            return 0  # Skip verification
            ;;
    esac
    return 1
}

# Main entry point for --setup-nodes
setup_remote_nodes() {
    show_banner

    log_step "Distribute configuration to cluster nodes"

    # Check prerequisites - use sudo to test file existence if not root
    local slurm_conf="/etc/slurm/slurm.conf"
    local munge_key="/etc/munge/munge.key"

    if [[ $EUID -ne 0 ]]; then
        log_info "Running as non-root user. Will use sudo to read config files."
        if ! sudo test -f "$slurm_conf"; then
            die "slurm.conf not found. Run the installer first to set up the controller."
        fi
        if ! sudo test -f "$munge_key"; then
            die "munge.key not found. Run the installer first to set up the controller."
        fi
    else
        if [[ ! -f "$slurm_conf" ]]; then
            die "slurm.conf not found. Run the installer first to set up the controller."
        fi
        if [[ ! -f "$munge_key" ]]; then
            die "munge.key not found. Run the installer first to set up the controller."
        fi
    fi

    # Select SSH connection mode
    select_ssh_mode

    # Get list of remote nodes
    local nodes
    nodes=$(get_remote_nodes)

    if [[ -z "$nodes" ]]; then
        log_warn "No remote nodes found in slurm.conf."

        # Check if we're on a controller and offer to add nodes
        if is_controller_node; then
            echo
            log_info "Would you like to add compute nodes now?"
            log_info "On each compute node, run 'slurmd -C' to get the hardware line."
            echo

            if confirm "Add compute nodes to slurm.conf?" "default_yes"; then
                # Source common.sh functions if not already loaded
                if ! declare -f detect_local_hardware &>/dev/null; then
                    source "${SCRIPT_DIR}/lib/common.sh"
                fi

                # Initialize variables
                COMPUTE_NODES=""
                CONTROLLER_IS_COMPUTE=false
                PARTITION_NAME="batch"

                gather_compute_nodes

                if [[ -n "$COMPUTE_NODES" ]]; then
                    if ! add_nodes_to_slurm_conf "$COMPUTE_NODES"; then
                        log_error "Failed to add nodes to slurm.conf"
                        exit 1
                    fi

                    # Reconfigure slurmctld to pick up changes
                    log_info "Reconfiguring slurmctld..."
                    if local_sudo scontrol reconfigure 2>/dev/null; then
                        log_success "Controller reconfigured."
                    fi

                    # Re-fetch nodes after adding them
                    nodes=$(get_remote_nodes)
                else
                    log_info "No compute nodes were added."
                    log_info "Node ranges (e.g., node[01-10]) must be distributed manually."
                    exit 0
                fi
            else
                log_info "Node ranges (e.g., node[01-10]) must be distributed manually."
                exit 0
            fi
        else
            log_info "Node ranges (e.g., node[01-10]) must be distributed manually."
            exit 0
        fi
    fi

    # If we still have no nodes after potentially adding them, exit
    if [[ -z "$nodes" ]]; then
        log_info "No distributable nodes (simple hostnames) found."
        log_info "Node ranges (e.g., node[01-10]) must be distributed manually."
        exit 0
    fi

    # Offer to review/update existing node configurations
    show_existing_nodes

    if confirm "Review or update node configurations before distributing?" "default_no"; then
        review_node_configs "$nodes"
        # Re-fetch in case node names changed (unlikely but possible)
        nodes=$(get_remote_nodes)
    fi

    echo
    log_info "Nodes to configure:"
    echo "$nodes" | while read -r node; do
        echo -e "  - ${node}"
    done
    echo

    case "$SSH_MODE" in
        root)
            log_info "Will SSH as root@<node> directly."
            ;;
        sudo_passwordless)
            log_info "Will SSH as ${SSH_USER}@<node> with passwordless sudo."
            ;;
        sudo_password)
            log_info "Will SSH as ${SSH_USER}@<node> with sudo (password prompt per node)."
            ;;
        *)
            die "Internal error: SSH_MODE not set. Run select_ssh_mode first."
            ;;
    esac
    log_warn "Ensure SSH key-based authentication is configured."
    echo

    if ! confirm "Proceed with distribution?" "default_yes"; then
        log_info "Cancelled."
        exit 0
    fi

    # Pre-flight: test SSH connectivity to all nodes
    echo
    log_info "Testing SSH connectivity..."
    local ssh_failures=0
    while read -r node; do
        if ! test_ssh_connectivity "$node"; then
            ((ssh_failures++)) || true
        fi
    done <<< "$nodes"

    if [[ $ssh_failures -gt 0 ]]; then
        echo
        log_error "SSH connectivity failed for ${ssh_failures} node(s). Fix the issues above and retry."
        exit 1
    fi
    log_success "All nodes reachable."

    # Ensure remote nodes can resolve controller hostname
    echo
    log_info "Ensuring hostname resolution on remote nodes..."
    while read -r node; do
        setup_remote_hostname_resolution "$node"
    done <<< "$nodes"

    echo
    local success_count=0
    local fail_count=0

    while read -r node; do
        if distribute_to_node "$node"; then
            ((success_count++)) || true
        else
            ((fail_count++)) || true
        fi
    done <<< "$nodes"

    echo
    if [[ $fail_count -eq 0 ]]; then
        log_success "All nodes configured successfully."
    else
        log_warn "Completed with errors: ${success_count} succeeded, ${fail_count} failed."
    fi

    # Restart munge on controller to ensure key sync
    echo
    log_info "Restarting munge on controller to ensure key sync..."
    if local_sudo systemctl restart munge 2>/dev/null; then
        sleep 1
        log_success "Controller munge restarted."
    else
        log_warn "Could not restart munge on controller."
    fi

    # Verify munge authentication to each node
    echo
    log_info "Verifying munge authentication to remote nodes..."
    local munge_ok=0
    local munge_fail=0
    while read -r node; do
        if verify_munge_to_node "$node"; then
            log_success "  ${node}: munge OK"
            ((munge_ok++)) || true
        else
            log_error "  ${node}: munge FAILED"
            ((munge_fail++)) || true
        fi
    done <<< "$nodes"

    if [[ $munge_fail -gt 0 ]]; then
        log_warn "Munge verification failed for ${munge_fail} node(s)."
        log_info "Check that munge is running on those nodes: systemctl status munge"
    fi

    # Reconfigure slurmctld to pick up any changes
    echo
    log_info "Running scontrol reconfigure..."
    if local_sudo scontrol reconfigure 2>/dev/null; then
        log_success "Controller reconfigured."
    else
        log_warn "scontrol reconfigure failed — controller may not be running."
    fi

    # Show cluster status
    echo
    log_info "Cluster status:"
    local_sudo sinfo 2>/dev/null || log_warn "Could not retrieve cluster status."
}

# ── Signal trap for partial state recovery ────────────────────────────────

INSTALL_PROGRESS=""

cleanup() {
    echo
    log_error "Installation interrupted!"
    if [[ -n "$INSTALL_PROGRESS" ]]; then
        log_info "Completed steps before interruption: ${INSTALL_PROGRESS}"
    else
        log_info "No installation steps were completed."
    fi
    log_info "You may need to re-run the installer to complete setup."
    exit 1
}

trap cleanup INT TERM

# ── Banner ────────────────────────────────────────────────────────────────

show_banner() {
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ____  _                        ___           _        _ _
 / ___|| |_   _ _ __ _ __ ___   |_ _|_ __  ___| |_ __ _| | | ___ _ __
 \___ \| | | | | '__| '_ ` _ \   | || '_ \/ __| __/ _` | | |/ _ \ '__|
  ___) | | |_| | |  | | | | | |  | || | | \__ \ || (_| | | |  __/ |
 |____/|_|\__,_|_|  |_| |_| |_| |___|_| |_|___/\__\__,_|_|_|\___|_|

BANNER
    echo -e "${RESET}"
    echo -e "  Interactive Slurm installer for Debian systems"
    echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo
}

# ── Role selection ────────────────────────────────────────────────────────

select_role() {
    menu_select "What role should this node serve?" \
        "Controller + Database  — All-in-one head node (recommended for small clusters)" \
        "Controller only        — Head node without local database" \
        "Database only          — Dedicated Slurm accounting database" \
        "Compute node           — Worker that executes jobs" \
        "Login node             — User-facing node (submit jobs, no daemons)"

    case "$REPLY" in
        1) NODE_ROLE="controller_db" ;;
        2) NODE_ROLE="controller" ;;
        3) NODE_ROLE="database" ;;
        4) NODE_ROLE="compute" ;;
        5) NODE_ROLE="login" ;;
    esac

    log_info "Selected role: ${NODE_ROLE}"
}

# ── Gather configuration ─────────────────────────────────────────────────

gather_config() {
    log_step "Cluster configuration"

    # Cluster name (needed by all roles)
    prompt_input "Cluster name" "mycluster"
    CLUSTER_NAME="$REPLY"

    # Controller hostname (needed by all roles)
    local default_hostname
    default_hostname="$(hostname -f 2>/dev/null || hostname)"

    case "$NODE_ROLE" in
        controller|controller_db)
            prompt_input "Controller hostname (this node)" "$default_hostname"
            ;;
        *)
            prompt_input "Controller hostname (the head node's FQDN or IP)"
            ;;
    esac
    CONTROLLER_HOSTNAME="$REPLY"

    if ! is_valid_hostname "$CONTROLLER_HOSTNAME" && ! is_valid_ip "$CONTROLLER_HOSTNAME"; then
        log_warn "'${CONTROLLER_HOSTNAME}' doesn't look like a valid hostname or IP."
        if ! confirm "Continue anyway?" "default_no"; then
            exit 1
        fi
    fi

    # Ensure controller hostname is resolvable (for non-controller roles)
    case "$NODE_ROLE" in
        compute|login|database)
            ensure_host_resolvable "$CONTROLLER_HOSTNAME" \
                "This node needs to communicate with the controller."
            ;;
    esac

    # Database hostname
    case "$NODE_ROLE" in
        controller_db)
            DBD_HOSTNAME="$CONTROLLER_HOSTNAME"
            ;;
        controller)
            if confirm "Will this cluster use an accounting database (slurmdbd)?" "default_yes"; then
                prompt_input "Database node hostname"
                DBD_HOSTNAME="$REPLY"
            fi
            ;;
        database)
            prompt_input "Database node hostname (this node)" "$default_hostname"
            DBD_HOSTNAME="$REPLY"
            ;;
        compute|login)
            if confirm "Does this cluster use an accounting database?" "default_yes"; then
                prompt_input "Database node hostname"
                DBD_HOSTNAME="$REPLY"
            fi
            ;;
    esac

    # Ensure database hostname is resolvable (if different from controller)
    if [[ -n "${DBD_HOSTNAME:-}" && "$DBD_HOSTNAME" != "$CONTROLLER_HOSTNAME" ]]; then
        ensure_host_resolvable "$DBD_HOSTNAME" \
            "This node needs to communicate with the database server."
    fi

    # Database credentials (only for roles that set up MariaDB)
    case "$NODE_ROLE" in
        controller_db|database)
            SLURM_DB_NAME="slurm_acct_db"
            SLURM_DB_USER="slurm"

            local generated_pass
            generated_pass="$(openssl rand -base64 16 2>/dev/null)" || die "Failed to generate random password. Ensure openssl is installed."
            prompt_password "MariaDB password for the 'slurm' user" "$generated_pass"
            SLURM_DB_PASS="$REPLY"

            if [[ "$SLURM_DB_PASS" == "$generated_pass" ]]; then
                log_info "Auto-generated password will be stored in /etc/slurm/slurmdbd.conf"
            fi
            ;;
    esac

    # UID/GID for slurm user (consistency across cluster is critical)
    echo
    log_info "The 'slurm' user UID/GID must be identical across all cluster nodes."
    if confirm "Use default UID/GID 64030?" "default_yes"; then
        SLURM_UID=64030
        SLURM_GID=64030
    else
        prompt_input "Slurm user UID"
        SLURM_UID="$REPLY"
        [[ "$SLURM_UID" =~ ^[0-9]+$ ]] && (( SLURM_UID > 0 )) || die "Invalid UID: must be a positive integer"
        prompt_input "Slurm group GID"
        SLURM_GID="$REPLY"
        [[ "$SLURM_GID" =~ ^[0-9]+$ ]] && (( SLURM_GID > 0 )) || die "Invalid GID: must be a positive integer"
    fi

    # Controller-as-compute option (controller roles only)
    case "$NODE_ROLE" in
        controller|controller_db)
            echo
            log_info "A controller can also run jobs as a compute node."
            log_info "This is common for small clusters or testing."

            if confirm "Should this controller ALSO act as a compute node?" "default_no"; then
                CONTROLLER_IS_COMPUTE=true
                if detect_local_hardware; then
                    show_detected_hardware
                    CONTROLLER_NODENAME=$(format_nodename_line)
                    log_success "Controller will be registered as compute node."
                else
                    log_warn "Could not auto-detect hardware."
                    log_info "After installation, run 'slurmd -C' and add this node manually."
                fi
            fi
            ;;
    esac

    # Compute node definitions (controller roles only)
    case "$NODE_ROLE" in
        controller|controller_db)
            echo
            log_info "You can define additional compute nodes now, or add them later."
            log_info "On each compute node, run 'slurmd -C' to get the hardware line."
            echo
            if confirm "Define additional compute nodes now?" "default_no"; then
                gather_compute_nodes
            else
                # Initialize COMPUTE_NODES with controller nodename if applicable
                if [[ -n "${CONTROLLER_NODENAME:-}" ]]; then
                    COMPUTE_NODES="$CONTROLLER_NODENAME"
                else
                    COMPUTE_NODES=""
                fi
                log_info "To add compute nodes later, run: ${CYAN}./install.sh --setup-nodes${RESET}"
            fi

            prompt_input "Default partition name" "batch"
            PARTITION_NAME="$REPLY"
            ;;
    esac
}

gather_compute_nodes() {
    # Include controller if it's also a compute node
    if [[ -n "${CONTROLLER_NODENAME:-}" ]]; then
        COMPUTE_NODES="$CONTROLLER_NODENAME"
    else
        COMPUTE_NODES=""
    fi

    echo
    echo -e "Enter compute node definitions one per line."
    echo -e "Format: ${CYAN}NodeName=<name> CPUs=<n> RealMemory=<MB> State=UNKNOWN${RESET}"
    echo -e "Or a shorter form: ${CYAN}<hostname> <cpus> <memory_mb>${RESET}"
    echo -e "Enter an empty line when done."

    # Show hint with local machine values if detection succeeded
    if [[ -n "${LOCAL_CPUS:-}" && -n "${LOCAL_MEMORY_MB:-}" ]]; then
        echo -e "${YELLOW}Hint:${RESET} This machine has ${LOCAL_CPUS} CPUs and ${LOCAL_MEMORY_MB} MB RAM."
    fi
    echo

    while true; do
        read -rp "Node> " line
        if [[ -z "$line" ]]; then
            break
        fi

        # If the user entered the short form: "hostname cpus memory"
        # Matches simple hostnames (node01) and Slurm ranges (node[01-10])
        if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
            local name="${BASH_REMATCH[1]}"
            local cpus="${BASH_REMATCH[2]}"
            local mem="${BASH_REMATCH[3]}"
            line="NodeName=${name} CPUs=${cpus} RealMemory=${mem} State=UNKNOWN"
            log_info "Expanded to: ${line}"
        fi

        # Extract hostname and ensure it's resolvable
        local node_hostname=""
        if [[ "$line" =~ NodeName=([^[:space:]]+) ]]; then
            node_hostname="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$node_hostname" ]]; then
            # Skip node ranges like node[01-10] — would need manual /etc/hosts entries
            if [[ "$node_hostname" =~ \[ ]]; then
                log_info "Node range detected — add individual hosts to /etc/hosts manually if needed."
            else
                ensure_host_resolvable "$node_hostname" \
                    "The controller needs to communicate with this compute node."
            fi
        fi

        if [[ -n "$COMPUTE_NODES" ]]; then
            COMPUTE_NODES="${COMPUTE_NODES}"$'\n'"${line}"
        else
            COMPUTE_NODES="$line"
        fi
    done
}

# ── Summary and confirmation ──────────────────────────────────────────────

show_summary() {
    local lines=()
    lines+=("${BOLD}Role:${RESET}              ${NODE_ROLE}")
    lines+=("${BOLD}Cluster:${RESET}           ${CLUSTER_NAME}")
    lines+=("${BOLD}Controller:${RESET}        ${CONTROLLER_HOSTNAME}")
    lines+=("${BOLD}Slurm UID/GID:${RESET}     ${SLURM_UID}/${SLURM_GID}")

    if [[ -n "${DBD_HOSTNAME:-}" ]]; then
        lines+=("${BOLD}Database host:${RESET}     ${DBD_HOSTNAME}")
    fi

    case "$NODE_ROLE" in
        controller_db|database)
            lines+=("${BOLD}DB name:${RESET}           ${SLURM_DB_NAME}")
            lines+=("${BOLD}DB user:${RESET}           ${SLURM_DB_USER}")
            ;;
    esac

    echo
    lines+=("")
    lines+=("${BOLD}What will be installed:${RESET}")

    case "$NODE_ROLE" in
        controller_db)
            lines+=("  - MUNGE (auth, key generation)")
            lines+=("  - MariaDB + slurmdbd (accounting)")
            lines+=("  - slurmctld (controller)")
            lines+=("  - slurm-client (CLI tools)")
            if $CONTROLLER_IS_COMPUTE; then
                lines+=("  - slurmd (compute daemon — this node is also a compute node)")
            fi
            ;;
        controller)
            lines+=("  - MUNGE (auth, key generation)")
            lines+=("  - slurmctld (controller)")
            lines+=("  - slurm-client (CLI tools)")
            if $CONTROLLER_IS_COMPUTE; then
                lines+=("  - slurmd (compute daemon — this node is also a compute node)")
            fi
            ;;
        database)
            lines+=("  - MUNGE (auth, key import)")
            lines+=("  - MariaDB + slurmdbd (accounting)")
            ;;
        compute)
            lines+=("  - MUNGE (auth, key import)")
            lines+=("  - slurmd (compute daemon)")
            lines+=("  - slurm-client (CLI tools)")
            ;;
        login)
            lines+=("  - MUNGE (auth, key import)")
            lines+=("  - slurm-client (CLI tools)")
            ;;
    esac

    print_summary "Installation Summary" "${lines[@]}"
}

# ── Installation orchestration ────────────────────────────────────────────

run_install() {
    # Determine MUNGE mode: controller/controller_db generate the key, others import
    local munge_mode="import"
    case "$NODE_ROLE" in
        controller|controller_db) munge_mode="generate" ;;
    esac

    # Step 1: Prerequisites (all roles)
    log_step "Step 1/4: System prerequisites"
    install_prereqs
    INSTALL_PROGRESS="prerequisites"

    # Step 2: MUNGE (all roles)
    log_step "Step 2/4: MUNGE authentication"
    setup_munge "$munge_mode"
    INSTALL_PROGRESS="prerequisites, munge"

    # Step 3: Role-specific setup
    log_step "Step 3/4: Role-specific installation (${NODE_ROLE})"
    case "$NODE_ROLE" in
        controller_db)
            setup_database
            setup_controller
            if $CONTROLLER_IS_COMPUTE; then
                log_info "This controller is also a compute node — installing slurmd..."
                install_compute_packages
                generate_gres_conf
                start_slurmd
            fi
            ;;
        controller)
            setup_controller
            if $CONTROLLER_IS_COMPUTE; then
                log_info "This controller is also a compute node — installing slurmd..."
                install_compute_packages
                generate_gres_conf
                start_slurmd
            fi
            ;;
        database)
            setup_database
            ;;
        compute)
            setup_compute
            ;;
        login)
            setup_login
            ;;
    esac
    INSTALL_PROGRESS="prerequisites, munge, ${NODE_ROLE} setup"

    # Step 4: Verification
    log_step "Step 4/4: Verification"
    verify_install
}

# ── Post-install verification ─────────────────────────────────────────────

verify_install() {
    local ok=true

    # Check MUNGE
    if is_service_active munge; then
        log_success "munge.service is running."
    else
        log_error "munge.service is NOT running."
        ok=false
    fi

    # Check role-specific services
    case "$NODE_ROLE" in
        controller_db)
            # Check MariaDB service (native or container)
            local mariadb_svc="mariadb"
            if $USE_MARIADB_CONTAINER; then
                mariadb_svc="slurm-mariadb"
            fi
            for svc in "$mariadb_svc" slurmdbd slurmctld; do
                if is_service_active "$svc"; then
                    log_success "${svc}.service is running."
                else
                    log_error "${svc}.service is NOT running."
                    ok=false
                fi
            done
            if $CONTROLLER_IS_COMPUTE; then
                if is_service_active slurmd; then
                    log_success "slurmd.service is running (controller is also a compute node)."
                else
                    log_error "slurmd.service is NOT running."
                    ok=false
                fi
            fi
            ;;
        controller)
            if is_service_active slurmctld; then
                log_success "slurmctld.service is running."
            else
                log_error "slurmctld.service is NOT running."
                ok=false
            fi
            if $CONTROLLER_IS_COMPUTE; then
                if is_service_active slurmd; then
                    log_success "slurmd.service is running (controller is also a compute node)."
                else
                    log_error "slurmd.service is NOT running."
                    ok=false
                fi
            fi
            ;;
        database)
            # Check MariaDB service (native or container)
            local mariadb_svc="mariadb"
            if $USE_MARIADB_CONTAINER; then
                mariadb_svc="slurm-mariadb"
            fi
            for svc in "$mariadb_svc" slurmdbd; do
                if is_service_active "$svc"; then
                    log_success "${svc}.service is running."
                else
                    log_error "${svc}.service is NOT running."
                    ok=false
                fi
            done
            ;;
        compute)
            if is_service_active slurmd; then
                log_success "slurmd.service is running."
            else
                log_error "slurmd.service is NOT running."
                ok=false
            fi
            ;;
        login)
            log_info "Login node has no Slurm daemons to verify."
            ;;
    esac

    # Check config files (slurmdbd-only nodes don't need slurm.conf)
    if [[ "$NODE_ROLE" != "database" ]]; then
        if [[ -f /etc/slurm/slurm.conf ]]; then
            log_success "slurm.conf exists."
        else
            log_warn "slurm.conf not found at /etc/slurm/slurm.conf."
        fi
    fi

    if [[ "$NODE_ROLE" == "controller_db" || "$NODE_ROLE" == "database" ]]; then
        if [[ -f /etc/slurm/slurmdbd.conf ]]; then
            log_success "slurmdbd.conf exists (mode $(stat -c %a /etc/slurm/slurmdbd.conf))."
        else
            log_warn "slurmdbd.conf not found."
        fi
    fi

    echo
    if $ok; then
        log_success "All checks passed!"
    else
        log_warn "Some checks failed. Review the output above."
    fi
}

# ── Post-install next steps ───────────────────────────────────────────────

show_next_steps() {
    echo
    log_step "Next steps"

    case "$NODE_ROLE" in
        controller_db)
            echo -e "  1. Run this installer on each compute/login node"
            echo -e "  2. Distribute configs to nodes (choose one):"
            echo -e "       ${CYAN}./install.sh --setup-nodes${RESET}  (automatic, requires SSH keys)"
            echo -e "       Or manually copy munge.key, slurm.conf, cgroup.conf"
            echo -e "  3. On each compute node, run ${CYAN}slurmd -C${RESET} and add the output to slurm.conf"
            echo -e "  4. After adding nodes, run ${CYAN}scontrol reconfigure${RESET} on the controller"
            echo -e "  5. Verify with ${CYAN}sinfo${RESET} — all nodes should show as 'idle'"
            echo -e "  6. Create accounts: ${CYAN}sacctmgr add account myaccount${RESET}"
            echo -e "  7. Add users: ${CYAN}sacctmgr add user myuser account=myaccount${RESET}"
            ;;
        controller)
            echo -e "  1. Run this installer on the database node first, then compute/login nodes"
            echo -e "  2. Distribute configs to nodes (choose one):"
            echo -e "       ${CYAN}./install.sh --setup-nodes${RESET}  (automatic, requires SSH keys)"
            echo -e "       Or manually copy munge.key, slurm.conf, cgroup.conf"
            echo -e "  3. On each compute node, run ${CYAN}slurmd -C${RESET} and add the output to slurm.conf"
            echo -e "  4. After adding nodes, run ${CYAN}scontrol reconfigure${RESET}"
            ;;
        database)
            echo -e "  1. Ensure the controller is configured with:"
            echo -e "     ${CYAN}AccountingStorageHost=${DBD_HOSTNAME}${RESET}"
            echo -e "  2. The database password was set during this install."
            echo -e "     Keep it secure — it's stored in ${CYAN}/etc/slurm/slurmdbd.conf${RESET}."
            ;;
        compute)
            echo -e "  1. Run ${CYAN}slurmd -C${RESET} and send the output to the cluster admin"
            echo -e "  2. The admin must add the NodeName line to slurm.conf on the controller"
            echo -e "  3. Then run ${CYAN}scontrol reconfigure${RESET} on the controller"
            echo -e "  4. Verify this node appears in ${CYAN}sinfo${RESET}"
            ;;
        login)
            echo -e "  1. Verify connectivity: ${CYAN}sinfo${RESET}"
            echo -e "  2. If sinfo fails, check that slurm.conf matches the controller exactly"
            echo -e "  3. Users can now submit jobs with ${CYAN}srun${RESET}, ${CYAN}sbatch${RESET}, etc."
            ;;
    esac

    echo
    echo -e "  Useful commands:"
    echo -e "    ${CYAN}sinfo${RESET}              — show cluster node/partition status"
    echo -e "    ${CYAN}squeue${RESET}             — show job queue"
    echo -e "    ${CYAN}scontrol show nodes${RESET} — detailed node info"
    echo -e "    ${CYAN}sacctmgr show assoc${RESET} — accounting associations"
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────

main() {
    show_banner
    require_root
    require_debian

    select_role
    gather_config
    show_summary

    if ! confirm "Proceed with installation?" "default_yes"; then
        log_info "Installation cancelled."
        exit 0
    fi

    run_install
    show_next_steps

    log_success "Slurm installation complete for role: ${NODE_ROLE}"
}

# ── Argument parsing ──────────────────────────────────────────────────────

case "${1:-}" in
    --setup-nodes)
        setup_remote_nodes
        ;;
    --uninstall)
        require_root
        uninstall_slurm
        ;;
    --help|-h)
        echo "Usage: $0 [--setup-nodes|--uninstall]"
        echo
        echo "Options:"
        echo "  --setup-nodes    Distribute config files to cluster nodes via SSH"
        echo "  --uninstall      Remove Slurm and MUNGE from this node"
        echo "  --help           Show this help message"
        echo
        echo "Run without arguments for interactive installation."
        exit 0
        ;;
    "")
        main "$@"
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Run '$0 --help' for usage." >&2
        exit 1
        ;;
esac
