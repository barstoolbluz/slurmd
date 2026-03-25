#!/usr/bin/env bash
# compute.sh — slurmd (compute node) setup
# Sourced by install.sh; requires common.sh to be loaded first.

# Show hardware detection early, before any installation prompts.
# This gives the user the NodeName line they need to send to the cluster admin.
show_compute_hardware_early() {
    log_step "Hardware detection"

    if ! detect_local_hardware; then
        log_warn "Could not auto-detect hardware. Will retry after slurmd is installed."
        return 0
    fi

    show_detected_hardware

    echo -e "  ${BOLD}${YELLOW}IMPORTANT:${RESET} Send the NodeName line above to your cluster administrator."
    echo -e "  They must add it to slurm.conf on the controller before this node can join."
    echo

    if ! confirm "Continue with installation?" "default_yes"; then
        echo
        echo -e "  Copy the NodeName line above, then re-run this installer when ready."
        exit 0
    fi
}

install_compute_packages() {
    log_step "Installing compute node packages"

    apt_install slurmd slurm-client slurm-wlm-basic-plugins

    log_success "Compute node packages installed."
}

fetch_slurm_conf_from_controller() {
    local conf_file="/etc/slurm/slurm.conf"
    local controller="${CONTROLLER_HOSTNAME:-}"

    if [[ -z "$controller" ]]; then
        prompt_input "Controller hostname or IP"
        controller="$REPLY"
    fi

    local default_user
    default_user=$(whoami)
    prompt_input "SSH username for ${controller}" "$default_user"
    local ssh_user="$REPLY"

    local ssh_target="${ssh_user}@${controller}"

    log_info "Fetching slurm.conf from ${ssh_target}..."
    echo -e "${YELLOW}You may be prompted for your SSH password and/or sudo password.${RESET}"
    echo

    # slurm.conf is world-readable (0644) so we don't need sudo on remote
    local tmp_conf
    tmp_conf=$(mktemp)

    if ssh -o ConnectTimeout=10 "$ssh_target" "cat /etc/slurm/slurm.conf" > "$tmp_conf" 2>/dev/null; then
        # Verify we got something reasonable
        if ! grep -q 'ClusterName=' "$tmp_conf"; then
            rm -f "$tmp_conf"
            die "Fetched file doesn't look like a valid slurm.conf"
        fi

        cp "$tmp_conf" "$conf_file"
        rm -f "$tmp_conf"
        log_success "slurm.conf fetched from ${controller}"

        # Also fetch cgroup.conf if it exists
        log_info "Checking for cgroup.conf on controller..."
        if ssh -o ConnectTimeout=10 "$ssh_target" "cat /etc/slurm/cgroup.conf" > /tmp/cgroup.conf 2>/dev/null; then
            if [[ -s /tmp/cgroup.conf ]]; then
                mv /tmp/cgroup.conf /etc/slurm/cgroup.conf
                chown root:root /etc/slurm/cgroup.conf
                chmod 0644 /etc/slurm/cgroup.conf
                log_success "cgroup.conf also fetched."
            fi
        fi
        rm -f /tmp/cgroup.conf

        # Also fetch gres.conf if it exists
        if ssh -o ConnectTimeout=10 "$ssh_target" "cat /etc/slurm/gres.conf" > /tmp/gres.conf 2>/dev/null; then
            if [[ -s /tmp/gres.conf ]]; then
                mv /tmp/gres.conf /etc/slurm/gres.conf
                chown root:root /etc/slurm/gres.conf
                chmod 0644 /etc/slurm/gres.conf
                log_success "gres.conf also fetched."
            fi
        fi
        rm -f /tmp/gres.conf
    else
        rm -f "$tmp_conf"
        log_error "Failed to fetch slurm.conf from ${controller}."
        log_info "Ensure you can SSH to the controller: ssh ${ssh_target}"
        die "Could not retrieve slurm.conf."
    fi
}

setup_slurm_conf_compute() {
    log_step "Setting up slurm.conf on compute node"

    local conf_file="/etc/slurm/slurm.conf"

    if [[ -f "$conf_file" ]]; then
        log_info "slurm.conf already exists at ${conf_file}."
        if ! confirm "Overwrite with new configuration?" "default_no"; then
            return 0
        fi
        backup_file "$conf_file"
    fi

    echo
    echo -e "The compute node needs the ${BOLD}same slurm.conf${RESET} as the controller."
    echo -e "How would you like to provide it?"
    echo -e "  ${CYAN}1)${RESET} Fetch from controller via SSH (recommended)"
    echo -e "  ${CYAN}2)${RESET} Specify a path to a local slurm.conf file"
    echo -e "  ${CYAN}3)${RESET} Skip — will be pushed from controller via --setup-nodes"
    echo -e "  ${CYAN}4)${RESET} Generate from scratch (must match controller values exactly)"
    echo

    menu_select "Choose an option:" \
        "Fetch from controller via SSH (recommended)" \
        "Path to local slurm.conf file" \
        "Skip — will be pushed from controller" \
        "Generate from scratch"
    local method="$REPLY"

    case "$method" in
        1)
            fetch_slurm_conf_from_controller
            ;;
        2)
            prompt_input "Path to slurm.conf"
            local src_path="$REPLY"

            if [[ ! -f "$src_path" ]]; then
                die "File not found: ${src_path}"
            fi

            cp "$src_path" "$conf_file"
            log_success "slurm.conf copied from ${src_path}."
            ;;
        3)
            log_info "Skipping slurm.conf setup."
            log_info "Run ${CYAN}./install.sh --setup-nodes${RESET} on the controller to push configs."
            SLURM_CONF_SKIPPED=true
            return 0
            ;;
        4)
            generate_slurm_conf_interactive
            ;;
    esac

    chown root:root "$conf_file"
    chmod 0644 "$conf_file"
}

generate_slurm_conf_interactive() {
    local conf_file="/etc/slurm/slurm.conf"
    local template="${SCRIPT_DIR}/config/templates/slurm.conf.tmpl"

    # These should have been collected in install.sh already, but prompt if missing
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        prompt_input "Cluster name (must match controller)"
        CLUSTER_NAME="$REPLY"
    fi
    if [[ -z "${CONTROLLER_HOSTNAME:-}" ]]; then
        prompt_input "Controller hostname (must match controller)"
        CONTROLLER_HOSTNAME="$REPLY"
    fi

    local acct_type="accounting_storage/none"
    local acct_extra="# No accounting database configured."

    if [[ -n "${DBD_HOSTNAME:-}" ]]; then
        acct_type="accounting_storage/slurmdbd"
        acct_extra="AccountingStorageHost=${DBD_HOSTNAME}"
    fi

    # Auto-detect this node's hardware
    local node_defs="# Compute nodes — ensure this matches the controller's slurm.conf"
    local partition_defs="# Partitions — ensure this matches the controller's slurm.conf"
    local gres_types="# GresTypes=gpu  # Ensure this matches the controller's slurm.conf"

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
        [CLUSTER_NAME]="${CLUSTER_NAME}"
        [CONTROLLER_HOSTNAME]="${CONTROLLER_HOSTNAME}"
        [ACCOUNTING_STORAGE_TYPE]="${acct_type}"
        [ACCOUNTING_STORAGE_EXTRA]="${acct_extra}"
        [GRES_TYPES]="${gres_types}"
        [NODE_DEFINITIONS]="${node_defs}"
        [PARTITION_DEFINITIONS]="${partition_defs}"
    )

    render_template "$template" "$conf_file" vars
    log_success "slurm.conf generated at ${conf_file}."
    log_warn "You MUST ensure the node and partition definitions match the controller's config."
}

setup_cgroup_conf_compute() {
    local conf_file="/etc/slurm/cgroup.conf"
    local template="${SCRIPT_DIR}/config/templates/cgroup.conf.tmpl"

    if [[ -f "$conf_file" ]]; then
        log_info "cgroup.conf already exists, keeping it."
        return 0
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
    )

    render_template "$template" "$conf_file" vars

    chown root:root "$conf_file"
    chmod 0644 "$conf_file"

    log_info "cgroup.conf written to ${conf_file}."
}

# Set up gres.conf for GPU support on compute nodes.
# Always creates gres.conf with AutoDetect=any so GPUs are discovered at slurmd startup.
# This handles cases where GPU drivers aren't installed at installer time but added later.
setup_gres_conf_compute() {
    local conf_file="/etc/slurm/gres.conf"
    local template="${SCRIPT_DIR}/config/templates/gres.conf.tmpl"

    if [[ -f "$conf_file" ]]; then
        log_info "gres.conf already exists, keeping it."
        return 0
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
    )

    render_template "$template" "$conf_file" vars

    chown root:root "$conf_file"
    chmod 0644 "$conf_file"

    if [[ "${LOCAL_GPU_COUNT:-0}" -gt 0 ]]; then
        log_success "gres.conf written to ${conf_file} (${LOCAL_GPU_COUNT} GPU(s) detected)."
    else
        log_info "gres.conf written to ${conf_file} (AutoDetect will find GPUs at slurmd startup)."
    fi
}

detect_hardware() {
    log_step "Verifying hardware detection"

    echo

    # slurmd -C uses hwloc for more accurate detection
    if command -v slurmd &>/dev/null; then
        local hw_line
        if hw_line=$(slurmd -C 2>/dev/null | head -1) && [[ -n "$hw_line" ]]; then
            log_info "Hardware detected by slurmd (uses hwloc for accuracy):"
            echo
            echo -e "  ${CYAN}${hw_line}${RESET}"
            echo

            # Compare with earlier /proc-based detection if available
            if [[ -n "${LOCAL_CPUS:-}" ]]; then
                # Extract values from slurmd output
                local slurmd_cpus slurmd_mem slurmd_gres
                slurmd_cpus=$(echo "$hw_line" | grep -oP 'CPUs=\K[0-9]+' || echo "")
                slurmd_mem=$(echo "$hw_line" | grep -oP 'RealMemory=\K[0-9]+' || echo "")
                slurmd_gres=$(echo "$hw_line" | grep -oP 'Gres=\K[^ ]+' || echo "")

                if [[ -n "$slurmd_cpus" && "$slurmd_cpus" != "$LOCAL_CPUS" ]]; then
                    log_info "Note: slurmd detected ${slurmd_cpus} CPUs (earlier estimate: ${LOCAL_CPUS})"
                    log_info "The slurmd value is typically more accurate."
                fi
                if [[ -n "$slurmd_mem" && "$slurmd_mem" != "$LOCAL_MEMORY_MB" ]]; then
                    log_info "Note: slurmd detected ${slurmd_mem} MB RAM (earlier estimate: ${LOCAL_MEMORY_MB} MB)"
                    log_info "The slurmd value accounts for reserved memory."
                fi

                # Check for GPU detection issues
                local slurmd_gpu_count=0
                if [[ -n "$slurmd_gres" ]]; then
                    slurmd_gpu_count=$(echo "$slurmd_gres" | grep -oP 'gpu:?\K[0-9]+' || echo "0")
                fi
                if [[ "${LOCAL_GPU_COUNT:-0}" -gt 0 && "$slurmd_gpu_count" -eq 0 ]]; then
                    log_warn "GPUs detected at install time but slurmd reports 0 GPUs."
                    log_warn "Ensure /etc/slurm/gres.conf exists and NVIDIA/AMD drivers are installed."
                elif [[ "${LOCAL_GPU_COUNT:-0}" -eq 0 && "$slurmd_gpu_count" -gt 0 ]]; then
                    log_info "slurmd detected ${slurmd_gpu_count} GPU(s) via gres.conf AutoDetect."
                fi
            fi

            echo -e "  ${BOLD}Ensure this NodeName line matches slurm.conf on the controller.${RESET}"
        else
            log_warn "slurmd -C could not detect hardware (config may be incomplete)."
            log_info "After setup is complete, run: slurmd -C"
        fi
    else
        log_warn "slurmd not yet available to detect hardware."
        log_info "After installation, run: slurmd -C"
    fi
    echo
}

start_slurmd() {
    log_step "Starting slurmd"
    enable_and_start slurmd
}

# ── Main entry point ───────────────────────────────────────────────────────

setup_compute() {
    show_compute_hardware_early
    install_compute_packages
    setup_slurm_conf_compute

    # If user chose to skip config (will be pushed from controller), don't start slurmd yet
    if [[ "${SLURM_CONF_SKIPPED:-false}" == "true" ]]; then
        log_info "slurmd will not be started until configs are pushed from the controller."
        log_info "After running --setup-nodes on the controller, start slurmd with:"
        echo -e "    ${CYAN}sudo systemctl start slurmd${RESET}"
        return 0
    fi

    setup_cgroup_conf_compute
    setup_gres_conf_compute
    detect_hardware
    start_slurmd
}
