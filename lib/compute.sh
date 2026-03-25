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
    echo -e "You can provide it in one of two ways:"
    echo -e "  ${CYAN}1)${RESET} Specify a path to a slurm.conf file (copied from the controller)"
    echo -e "  ${CYAN}2)${RESET} Generate one now (you must provide the same values as the controller)"
    echo

    menu_select "How would you like to provide slurm.conf?" \
        "Path to existing slurm.conf" \
        "Generate from scratch"
    local method="$REPLY"

    case "$method" in
        1)
            prompt_input "Path to slurm.conf"
            local src_path="$REPLY"

            if [[ ! -f "$src_path" ]]; then
                die "File not found: ${src_path}"
            fi

            cp "$src_path" "$conf_file"
            log_success "slurm.conf copied from ${src_path}."
            ;;
        2)
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
# Only creates gres.conf if NVIDIA GPUs are detected.
setup_gres_conf_compute() {
    local conf_file="/etc/slurm/gres.conf"
    local template="${SCRIPT_DIR}/config/templates/gres.conf.tmpl"

    # Only needed if this node has GPUs
    if [[ "${LOCAL_HAS_NVIDIA:-false}" != "true" ]]; then
        log_info "No NVIDIA GPUs detected — skipping gres.conf."
        return 0
    fi

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

    log_success "gres.conf written to ${conf_file} (${LOCAL_GPU_COUNT} GPU(s) detected)."
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
                local slurmd_cpus slurmd_mem
                slurmd_cpus=$(echo "$hw_line" | grep -oP 'CPUs=\K[0-9]+' || echo "")
                slurmd_mem=$(echo "$hw_line" | grep -oP 'RealMemory=\K[0-9]+' || echo "")

                if [[ -n "$slurmd_cpus" && "$slurmd_cpus" != "$LOCAL_CPUS" ]]; then
                    log_info "Note: slurmd detected ${slurmd_cpus} CPUs (earlier estimate: ${LOCAL_CPUS})"
                    log_info "The slurmd value is typically more accurate."
                fi
                if [[ -n "$slurmd_mem" && "$slurmd_mem" != "$LOCAL_MEMORY_MB" ]]; then
                    log_info "Note: slurmd detected ${slurmd_mem} MB RAM (earlier estimate: ${LOCAL_MEMORY_MB} MB)"
                    log_info "The slurmd value accounts for reserved memory."
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
    setup_cgroup_conf_compute
    setup_gres_conf_compute
    detect_hardware
    start_slurmd
}
